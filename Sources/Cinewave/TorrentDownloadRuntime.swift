import Foundation

/// A small WebTorrent API helper gives the player explicit control of file
/// selection and durable storage, without launching an external media player.
enum TorrentDownloadRuntime {
    static func write(to url: URL) throws {
        try Data(script.utf8).write(to: url, options: .atomic)
    }

    static let script = #"""
    import fs from 'node:fs/promises'
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

    function finish(code = 0) {
      if (stopping) return
      stopping = true
      // Never destroy the store: completed files and verified partial pieces
      // are reused on the next launch. Bound shutdown if a peer does not close.
      const deadline = setTimeout(() => process.exit(code), 1500)
      deadline.unref()
      if (client) client.destroy(() => process.exit(code))
      else process.exit(code)
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
          const server = client.createServer({ hostname: '127.0.0.1' })
          server.server.on('error', fail)
          await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
          while (!stopping) {
            const command = JSON.parse(await fs.readFile(controlPath, 'utf8'))
            if (command.requestID !== lastRequestID) {
              const index = command.index ?? playable[0].index
              if (!playable.some(item => item.index === index)) throw new Error('Invalid torrent file selection')
              selectedIndex = index
              lastRequestID = command.requestID
              schedule()
              const filePath = torrent.files[index].path.split('/').map(encodeURIComponent).join('/')
              const url = `http://127.0.0.1:${server.address().port}${server.pathname}/${torrent.infoHash}/${filePath}`
              await atomicWrite(outputPath, JSON.stringify({ requestID: lastRequestID, url }), lastRequestID)
            }
            await new Promise(resolve => setTimeout(resolve, 100))
          }
        } catch (error) { if (!stopping) fail(error) }
      })
    } catch (error) { fail(error) }
    """#
}
