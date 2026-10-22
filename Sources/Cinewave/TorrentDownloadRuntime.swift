import Foundation

/// A small WebTorrent API helper gives the player explicit control of file
/// selection and durable storage, without launching an external media player.
enum TorrentDownloadRuntime {
    static func write(to url: URL) throws {
        try Data(script.utf8).write(to: url, options: .atomic)
    }

    static let script = #"""
    import { createReadStream } from 'node:fs'
    import fs from 'node:fs/promises'
    import http from 'node:http'
    import path from 'node:path'
    import { createRequire } from 'node:module'
    import { pathToFileURL } from 'node:url'

    const [modulePath, identifier, downloadRoot, outputPath, controlPath, extensionsJSON, allowedIndexesJSON] = process.argv.slice(2)
    const mediaExtensions = new Set(JSON.parse(extensionsJSON))
    const allowedIndexes = allowedIndexesJSON && allowedIndexesJSON !== 'null'
      ? new Set(JSON.parse(allowedIndexesJSON)) : null
    const require = createRequire(pathToFileURL(modulePath))
    async function resolveDependency(name) {
      try { return require.resolve(name) } catch (error) {
        if (error.code !== 'ERR_PACKAGE_PATH_NOT_EXPORTED') throw error
        for (const directory of require.resolve.paths(name)) {
          const entry = path.join(directory, name, 'index.js')
          try { await fs.access(entry); return entry } catch {}
        }
        throw error
      }
    }
    let client
    let stopping = false
    let httpServer = null

    function waitForDrain(response) {
      return new Promise(resolve => {
        const done = () => {
          response.off('drain', done)
          response.off('close', done)
          response.off('error', done)
          resolve()
        }
        response.once('drain', done)
        response.once('close', done)
        response.once('error', done)
        if (response.destroyed || response.writableEnded) done()
      })
    }

    // Leaves the swarm. Never destroys the store: completed files and verified
    // partial pieces are reused on the next launch.
    let clientClosed = null
    function closeClient() {
      clientClosed ??= new Promise(resolve => {
        if (!client) { resolve(); return }
        try { client.destroy(resolve) } catch { resolve() }
      })
      return clientClosed
    }

    function finish(code = 0) {
      if (stopping) return
      stopping = true
      // Bound shutdown if a peer does not close.
      const deadline = setTimeout(() => process.exit(code), 1500)
      const closeServer = new Promise(resolve => {
        if (!httpServer) { resolve(); return }
        try {
          httpServer.close(resolve)
          httpServer.closeAllConnections()
        } catch { resolve() }
      })
      Promise.all([closeClient(), closeServer]).then(() => {
        clearTimeout(deadline)
        process.exit(code)
      })
    }
    function fail(error) {
      console.error(error?.stack || String(error))
      finish(1)
    }
    process.on('SIGTERM', () => finish())
    process.on('SIGINT', () => finish())
    // A crashed or force-quit app never sends SIGTERM. Orphans are reparented,
    // so a changed ppid means the app is gone; stop instead of seeding forever.
    const parentPID = process.ppid
    setInterval(() => { if (process.ppid !== parentPID) finish() }, 2000).unref()

    async function atomicWrite(destination, contents, suffix = 'tmp') {
      const temporary = `${destination}.${suffix}`
      await fs.writeFile(temporary, contents)
      await fs.rename(temporary, destination)
    }

    try {
      const { default: WebTorrent } = await import(pathToFileURL(modulePath).href)
      const { default: parseTorrent } = await import(pathToFileURL(await resolveDependency('parse-torrent')).href)
      const input = identifier.toLowerCase().startsWith('magnet:') ? identifier : await fs.readFile(identifier)
      const parsed = await parseTorrent(input)
      const hash = parsed.infoHash
      if (!/^[a-f0-9]{40}$/i.test(hash)) throw new Error('Unsupported torrent info hash')
      const downloadPath = path.join(downloadRoot, hash.toLowerCase())
      const metadataDirectory = path.join(downloadRoot, '.metadata')
      const metadataPath = path.join(metadataDirectory, `${hash.toLowerCase()}.torrent`)
      const progressPath = path.join(metadataDirectory, `${hash.toLowerCase()}.progress.json`)
      await fs.mkdir(downloadPath, { recursive: true })
      await fs.mkdir(metadataDirectory, { recursive: true })
      let source = input
      try { source = await fs.readFile(metadataPath) } catch (error) {
        if (error.code !== 'ENOENT') throw error
      }
      client = new WebTorrent({ downloadLimit: -1 })
      client.on('error', fail)
      // Start with nothing selected. Verification reads existing files first;
      // only the chosen video's pieces may download until that file is done.
      const torrent = client.add(source, {
        path: downloadPath, deselect: true, strategy: 'sequential',
        destroyStoreOnDestroy: false
      })
      torrent.on('error', fail)
      torrent.on('warning', warning => console.error(warning?.message || String(warning)))
      torrent.once('ready', async () => {
        try {
          if (stopping) return
          await atomicWrite(metadataPath, torrent.torrentFile)
          const playable = torrent.files.map((file, index) => ({ file, index }))
            .filter(({ file, index }) => mediaExtensions.has(path.extname(file.path).slice(1).toLowerCase()) &&
              (allowedIndexes === null || allowedIndexes.has(index)))
            .sort((a, b) => a.file.path.localeCompare(b.file.path, 'en', { numeric: true, sensitivity: 'base' }))
          if (!playable.length) throw new Error('No supported media files in this torrent')
          // torrent.files empties when the client closes; streaming outlives it.
          const files = [...torrent.files]
          const infoHash = torrent.infoHash
          const servable = new Set(playable.map(({ index }) => index))
          let selectedIndex = null
          let downloading = null
          let lastRequestID = null
          let complete = false
          let pendingReads = 0
          // The queue sidebar reads every media file's progress from here, also
          // for torrents that are not running. Writes are serialized and skip
          // unchanged snapshots; a closed client reports nothing downloaded.
          let savedProgress = null
          let progressWrites = Promise.resolve()
          function saveProgress() {
            if (stopping || clientClosed) return
            const snapshot = {}
            files.forEach((file, index) => {
              if (!mediaExtensions.has(path.extname(file.path).slice(1).toLowerCase())) return
              // file.downloaded misses pieces shared with neighbouring files.
              const downloaded = file.done ? file.length : Math.min(file.downloaded, file.length)
              snapshot[index] = { downloaded, done: file.done }
            })
            const contents = JSON.stringify({ files: snapshot })
            if (contents === savedProgress) return
            savedProgress = contents
            progressWrites = progressWrites
              .then(() => atomicWrite(progressPath, contents))
              .catch(error => console.error(error?.message || String(error)))
          }
          setInterval(saveProgress, 1000).unref()
          // Stop sharing once every queued video is saved: leave the swarm and
          // serve from disk. Streams waiting on a torrent read finish it first.
          // Deferred: WebTorrent breaks if destroyed inside its 'done' callbacks.
          function leaveSwarmIfComplete() {
            if (!complete && playable.every(({ file }) => file.done)) {
              complete = true
              saveProgress()
            }
            if (complete && pendingReads === 0) setImmediate(closeClient)
          }
          function schedule() {
            if (stopping || complete || selectedIndex === null) return
            const selected = torrent.files[selectedIndex]
            const next = !selected.done ? selected : playable.find(({ file }) => !file.done)?.file
            if (next === downloading) return
            downloading?.deselect()
            downloading = next
            downloading?.select()
          }
          for (const { file } of playable) {
            file.on('done', () => {
              schedule()
              leaveSwarmIfComplete()
            })
          }
          // Serve by numeric file index, never by file path. WebTorrent's
          // built-in server routes `/:infoHash/:path` and decodes with
          // decodeURI, which leaves %2B/%23/%3F/%26/... encoded, so any
          // release name containing `+` (e.g. `DD+`), `#`, `?`, `&`, `;`
          // 404s and mpv reports "Loading failed". Index URLs contain only
          // hex and digits and cannot suffer filename-encoding mismatches.
          httpServer = http.createServer((req, res) => {
            handleRequest(req, res).catch(() => {
              try {
                if (!res.headersSent) { res.writeHead(500); res.end() }
                else res.destroy()
              } catch {}
            })
          })
          async function handleRequest(req, res) {
            const port = httpServer.address()?.port
            if (req.headers.host !== `127.0.0.1:${port}`) {
              try { req.socket.destroy() } catch {}
              return
            }
            if (req.method !== 'GET' && req.method !== 'HEAD') {
              res.writeHead(405); res.end(); return
            }
            let parts
            try {
              parts = new URL(req.url, 'http://127.0.0.1').pathname.split('/').filter(Boolean)
            } catch { res.writeHead(400); res.end(); return }
            if (parts.length !== 2) { res.writeHead(404); res.end(); return }
            const [requestHash, indexText] = parts
            if (requestHash.toLowerCase() !== infoHash.toLowerCase()) {
              res.writeHead(404); res.end(); return
            }
            if (!/^\d+$/.test(indexText)) { res.writeHead(404); res.end(); return }
            const fileIndex = Number(indexText)
            const file = files[fileIndex]
            if (!file || !servable.has(fileIndex)) { res.writeHead(404); res.end(); return }
            if (file.length === 0) {
              res.writeHead(200, {
                'Accept-Ranges': 'bytes',
                'Content-Type': file.type || 'application/octet-stream',
                'Content-Length': 0
              })
              res.end(); return
            }
            let start = 0
            let end = file.length - 1
            let status = 200
            const range = req.headers.range
            if (range) {
              const match = /^bytes=(\d*)-(\d*)$/.exec(range)
              if (!match) { res.writeHead(416, { 'Content-Range': `bytes */${file.length}` }); res.end(); return }
              if (match[1] === '' && match[2] === '') {
                res.writeHead(416, { 'Content-Range': `bytes */${file.length}` }); res.end(); return
              }
              if (match[1] === '') {
                const suffix = Number(match[2])
                if (!Number.isSafeInteger(suffix)) {
                  res.writeHead(416, { 'Content-Range': `bytes */${file.length}` }); res.end(); return
                }
                start = Math.max(0, file.length - suffix)
              } else if (match[2] === '') {
                start = Number(match[1])
              } else {
                start = Number(match[1]); end = Number(match[2])
              }
              if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) ||
                  start >= file.length || end >= file.length || start > end) {
                res.writeHead(416, { 'Content-Range': `bytes */${file.length}` }); res.end(); return
              }
              status = 206
            }
            const headers = {
              'Accept-Ranges': 'bytes',
              'Content-Type': file.type || 'application/octet-stream',
              'Content-Length': end - start + 1
            }
            if (status === 206) headers['Content-Range'] = `bytes ${start}-${end}/${file.length}`
            res.writeHead(status, headers)
            if (req.method === 'HEAD') { res.end(); return }
            let source = null
            let closed = false
            let position = start
            const onClose = () => {
              closed = true
              // Stop waiting for torrent pieces as soon as mpv disconnects.
              try { source?.destroy?.() } catch {}
            }
            const gone = () => closed || stopping || res.destroyed || res.writableEnded
            async function send(chunk) {
              position += chunk.length
              if (!res.write(chunk)) await waitForDrain(res)
            }
            res.once('close', onClose)
            try {
              // Unfinished files stream from the torrent until they complete;
              // the rest always comes from disk, which outlives the swarm.
              if (!file.done) {
                source = file[Symbol.asyncIterator]({ start, end })
                while (!file.done && !gone() && position <= end) {
                  pendingReads++
                  let result
                  try { result = await source.next() } finally {
                    pendingReads--
                    leaveSwarmIfComplete()
                  }
                  if (result.done || gone()) break
                  await send(result.value)
                }
                try { await source.return?.() } catch {}
              }
              if (file.done && !gone() && position <= end) {
                source = createReadStream(path.join(downloadPath, file.path), { start: position, end })
                for await (const chunk of source) {
                  if (gone()) break
                  await send(chunk)
                }
              }
              if (!res.writableEnded && !res.destroyed) res.end()
            } catch (error) {
              try { res.destroy() } catch {}
            } finally {
              res.off('close', onClose)
              try { source?.destroy?.() } catch {}
            }
          }
          httpServer.on('error', fail)
          await new Promise((resolve, reject) => {
            httpServer.once('error', reject)
            httpServer.listen(0, '127.0.0.1', resolve)
          })
          const streamPort = httpServer.address().port
          // A reopened torrent may already be complete; it never joins the swarm for long.
          saveProgress()
          leaveSwarmIfComplete()
          while (!stopping) {
            const command = JSON.parse(await fs.readFile(controlPath, 'utf8'))
            if (command.requestID !== lastRequestID) {
              const index = command.index ?? playable[0].index
              if (!playable.some(item => item.index === index)) throw new Error('Invalid torrent file selection')
              selectedIndex = index
              lastRequestID = command.requestID
              schedule()
              const url = `http://127.0.0.1:${streamPort}/${infoHash}/${index}`
              await atomicWrite(outputPath, JSON.stringify({ requestID: lastRequestID, url }), lastRequestID)
            }
            await new Promise(resolve => setTimeout(resolve, 100))
          }
        } catch (error) { if (!stopping) fail(error) }
      })
    } catch (error) { fail(error) }
    """#
}
