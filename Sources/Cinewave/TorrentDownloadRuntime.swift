import Foundation

/// A small WebTorrent API helper gives the player explicit control of file
/// selection and durable storage, without launching an external media player.
enum TorrentDownloadRuntime {
    static func write(to url: URL) throws {
        try Data(script.utf8).write(to: url, options: .atomic)
    }

    static let script = #"""
    import fs from 'node:fs/promises'
    import http from 'node:http'
    import path from 'node:path'
    import { createRequire } from 'node:module'
    import { pathToFileURL } from 'node:url'

    const [modulePath, identifier, downloadRoot, outputPath, controlPath, extensionsJSON] = process.argv.slice(2)
    const mediaExtensions = new Set(JSON.parse(extensionsJSON))
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

    function finish(code = 0) {
      if (stopping) return
      stopping = true
      // Never destroy the store: completed files and verified partial pieces
      // are reused on the next launch. Bound shutdown if a peer does not close.
      const deadline = setTimeout(() => process.exit(code), 1500)
      const closeClient = new Promise(resolve => {
        if (!client) { resolve(); return }
        try { client.destroy(resolve) } catch { resolve() }
      })
      const closeServer = new Promise(resolve => {
        if (!httpServer) { resolve(); return }
        try {
          httpServer.close(resolve)
          httpServer.closeAllConnections()
        } catch { resolve() }
      })
      Promise.all([closeClient, closeServer]).then(() => {
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
            .filter(({ file }) => mediaExtensions.has(path.extname(file.path).slice(1).toLowerCase()))
            .sort((a, b) => a.file.path.localeCompare(b.file.path, 'en', { numeric: true, sensitivity: 'base' }))
          if (!playable.length) throw new Error('No supported media files in this torrent')
          let selectedIndex = null
          let downloading = null
          let lastRequestID = null
          function schedule() {
            if (stopping || selectedIndex === null) return
            const selected = torrent.files[selectedIndex]
            const next = !selected.done ? selected : playable.find(({ file }) => !file.done)?.file
            if (next === downloading) return
            downloading?.deselect()
            downloading = next
            downloading?.select()
          }
          for (const { file } of playable) file.on('done', schedule)
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
            if (requestHash.toLowerCase() !== torrent.infoHash.toLowerCase()) {
              res.writeHead(404); res.end(); return
            }
            if (!/^\d+$/.test(indexText)) { res.writeHead(404); res.end(); return }
            const fileIndex = Number(indexText)
            const file = torrent.files[fileIndex]
            if (!file) { res.writeHead(404); res.end(); return }
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
            const iterator = file[Symbol.asyncIterator]({ start, end })
            let closed = false
            const onClose = () => {
              closed = true
              // Stop waiting for torrent pieces as soon as mpv disconnects.
              try { iterator.destroy?.() } catch {}
            }
            res.once('close', onClose)
            try {
              for await (const chunk of iterator) {
                if (closed || stopping || res.destroyed || res.writableEnded) break
                if (!res.write(chunk)) await waitForDrain(res)
                if (closed || res.destroyed) break
              }
              if (!res.writableEnded && !res.destroyed) res.end()
            } catch (error) {
              try { res.destroy() } catch {}
            } finally {
              res.off('close', onClose)
              try { await iterator.return?.() } catch {}
              try { iterator.destroy?.() } catch {}
            }
          }
          httpServer.on('error', fail)
          await new Promise((resolve, reject) => {
            httpServer.once('error', reject)
            httpServer.listen(0, '127.0.0.1', resolve)
          })
          const streamPort = httpServer.address().port
          while (!stopping) {
            const command = JSON.parse(await fs.readFile(controlPath, 'utf8'))
            if (command.requestID !== lastRequestID) {
              const index = command.index ?? playable[0].index
              if (!playable.some(item => item.index === index)) throw new Error('Invalid torrent file selection')
              selectedIndex = index
              lastRequestID = command.requestID
              schedule()
              const url = `http://127.0.0.1:${streamPort}/${torrent.infoHash}/${index}`
              await atomicWrite(outputPath, JSON.stringify({ requestID: lastRequestID, url }), lastRequestID)
            }
            await new Promise(resolve => setTimeout(resolve, 100))
          }
        } catch (error) { if (!stopping) fail(error) }
      })
    } catch (error) { fail(error) }
    """#
}
