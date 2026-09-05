import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'
import http from 'node:http'
import { createRequire } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { spawn } from 'node:child_process'
import { EventEmitter } from 'node:events'

const project = fileURLToPath(new URL('../', import.meta.url))
const modulePath = process.env.MACMPV_WEBTORRENT_MODULE || path.join(project, 'dist/macmpv.app/Contents/Resources/webtorrent-cli/node_modules/webtorrent/index.js')
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
const { default: createTorrent } = await import(pathToFileURL(await resolveDependency('create-torrent')).href)
const { default: parseTorrent } = await import(pathToFileURL(await resolveDependency('parse-torrent')).href)

// Exercise the embedded runtime's lifecycle functions with controlled callback
// ordering; a normal download can finish too quickly to expose these races.
const embeddedSource = await fs.readFile(path.join(project, 'Sources/Cinewave/TorrentDownloadRuntime.swift'), 'utf8')
const embeddedRuntime = /static let script = #"""\n([\s\S]*?)\n    """#/.exec(embeddedSource)[1]

test('shutdown waits for both torrent storage and HTTP closure', async () => {
  for (const first of ['client', 'server']) {
    const callbacks = {}
    const exits = []
    let connectionsClosed = false
    const finishSource = embeddedRuntime.slice(embeddedRuntime.indexOf('function finish('), embeddedRuntime.indexOf('function fail('))
    const finish = new Function('client', 'httpServer', 'process', `let stopping = false; ${finishSource}; return finish`)(
      { destroy: callback => { callbacks.client = callback } },
      { close: callback => { callbacks.server = callback }, closeAllConnections: () => { connectionsClosed = true } },
      { exit: code => exits.push(code) }
    )
    finish()
    assert.ok(connectionsClosed)
    callbacks[first]()
    await new Promise(resolve => setImmediate(resolve))
    assert.deepEqual(exits, [], `Exited before ${first === 'server' ? 'storage' : 'HTTP'} closed`)
    callbacks[first === 'server' ? 'client' : 'server']()
    await new Promise(resolve => setImmediate(resolve))
    assert.deepEqual(exits, [0])
    finish()
    assert.deepEqual(exits, [0], 'Repeated shutdown exited twice')
  }
})

test('backpressure releases on disconnect or error and removes its listeners', { timeout: 2000 }, async () => {
  const source = embeddedRuntime.slice(embeddedRuntime.indexOf('function waitForDrain('), embeddedRuntime.indexOf('function finish('))
  const waitForDrain = new Function(`${source}; return waitForDrain`)()
  for (const event of ['drain', 'close', 'error', 'already-closed']) {
    const response = new EventEmitter()
    response.destroyed = event === 'already-closed'
    const pending = waitForDrain(response)
    if (event !== 'already-closed') response.emit(event)
    await pending
    for (const name of ['drain', 'close', 'error']) assert.equal(response.listenerCount(name), 0)
  }
})

async function until(predicate, message) {
  const deadline = Date.now() + 12000
  while (Date.now() < deadline) {
    const result = await predicate()
    if (result) return result
    await new Promise(resolve => setTimeout(resolve, 20))
  }
  throw new Error(message)
}
async function readJSON(file) {
  try { return JSON.parse(await fs.readFile(file, 'utf8')) } catch { return null }
}
async function fixture(t, size = 512 * 1024) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'macmpv-torrent-integration-'))
  const children = []
  let failures = ''
  let requests = []
  let serveData = true
  const payloads = new Map([
    ['episode2.mp4', Buffer.alloc(size, 31)],
    ['episode10.mp4', Buffer.alloc(size, 97)],
    ['readme.txt', Buffer.alloc(16384, 122)]
  ])
  const server = http.createServer((req, res) => {
    const name = decodeURIComponent(req.url.split('/').at(-1))
    const data = payloads.get(name)
    if (!serveData || !data) { res.writeHead(503); res.end(); return }
    requests.push(name)
    const range = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || '')
    const start = range ? Number(range[1]) : 0
    const end = range && range[2] ? Number(range[2]) : data.length - 1
    res.writeHead(range ? 206 : 200, {
      'Content-Length': end - start + 1,
      'Accept-Ranges': 'bytes',
      ...(range ? { 'Content-Range': `bytes ${start}-${end}/${data.length}` } : {})
    })
    setTimeout(() => res.end(data.subarray(start, end + 1)), 40)
  })
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  async function stop(child) {
    if (child.exitCode !== null || child.signalCode !== null) return
    await new Promise(resolve => {
      child.once('exit', resolve)
      child.kill('SIGTERM')
      const timer = setTimeout(() => child.kill('SIGKILL'), 2500)
      timer.unref()
      child.once('exit', () => clearTimeout(timer))
    })
  }
  t.after(async () => {
    for (const child of children) await stop(child)
    server.closeAllConnections()
    await new Promise(resolve => server.close(resolve))
    await fs.rm(root, { recursive: true, force: true })
  })
  const seed = path.join(root, 'seed')
  await fs.mkdir(seed)
  for (const [name, data] of payloads) await fs.writeFile(path.join(seed, name), data)
  const bytes = await new Promise((resolve, reject) => createTorrent(
    [...payloads.keys()].map(name => path.join(seed, name)),
    { name: 'series', pieceLength: 16384, announceList: [], urlList: [`http://127.0.0.1:${server.address().port}/`] },
    (error, result) => error ? reject(error) : resolve(result)
  ))
  const parsed = await parseTorrent(bytes)
  const torrentFile = path.join(root, 'fixture.torrent')
  await fs.writeFile(torrentFile, bytes)
  const source = await fs.readFile(path.join(project, 'Sources/Cinewave/TorrentDownloadRuntime.swift'), 'utf8')
  const runtime = /static let script = #"""\n([\s\S]*?)\n    """#/.exec(source)[1].split('\n').map(line => line.slice(4)).join('\n')
  await fs.writeFile(path.join(root, 'runtime.mjs'), runtime)
  const swift = await fs.readFile(path.join(project, 'Sources/Cinewave/MagnetStream.swift'), 'utf8')
  for (const [variable, name] of [['bootstrap', 'webtorrent-bootstrap.mjs'], ['loader', 'webtorrent-loader.mjs']]) {
    const embedded = new RegExp(`let ${variable} = """\\n([\\s\\S]*?)\\n        """`).exec(swift)[1]
    await fs.writeFile(path.join(root, name), embedded.split('\n').map(line => line.slice(8)).join('\n'))
  }
  await fs.symlink(path.dirname(path.dirname(modulePath)), path.join(root, 'node_modules'))
  const eventsPath = path.join(root, 'selections.jsonl')
  const helperDirectory = path.join(root, 'helper')
  await fs.mkdir(helperDirectory)
  await fs.symlink(path.join(path.dirname(modulePath), 'node_modules'), path.join(helperDirectory, 'node_modules'))
  const wrapper = path.join(helperDirectory, 'webtorrent.mjs')
  await fs.writeFile(wrapper, `
    import WebTorrent from ${JSON.stringify(pathToFileURL(modulePath).href)};
    import { appendFileSync } from 'node:fs';
    export default class extends WebTorrent {
      constructor(opts) { super({...opts, dht:false, tracker:false, lsd:false, natUpnp:false, natPmp:false, utp:false}); }
      add(source, opts) {
        const torrent = super.add(source, opts);
        torrent.on('ready', () => {
          for (const file of torrent.files) {
            const select = file.select.bind(file);
            file.select = (...args) => {
              appendFileSync(${JSON.stringify(eventsPath)}, JSON.stringify({name:file.name, done:torrent.files.filter(f => f.done).map(f => f.name)}) + '\\n');
              return select(...args);
            };
          }
        });
        return torrent;
      }
    }
  `)
  const metadataScript = /private static func writeMetadataScript[\s\S]*?let script = """\n([\s\S]*?)\n        """/.exec(swift)[1]
  await fs.writeFile(path.join(root, 'metadata.mjs'), metadataScript.split('\n').map(line => line.slice(8)).join('\n'))
  const saved = path.join(root, 'saved')
  const output = path.join(root, 'stream.json')
  const control = path.join(root, 'selection.json')
  async function select(name, requestID) {
    const index = parsed.files.findIndex(file => path.basename(file.path) === name)
    await fs.writeFile(control + '.tmp', JSON.stringify({ index, requestID }))
    await fs.rename(control + '.tmp', control)
  }
  async function ready(requestID) {
    return until(async () => {
      const response = await readJSON(output)
      return response?.requestID === requestID ? response : false
    }, 'No stream response: ' + failures)
  }
  function launch(identifier = torrentFile) {
    const child = spawn(process.execPath, [
      '--import=' + path.join(root, 'webtorrent-bootstrap.mjs'), path.join(root, 'runtime.mjs'),
      wrapper, identifier, saved, output, control, JSON.stringify(['mp4'])
    ], { stdio: ['ignore', 'ignore', 'pipe'] })
    child.stderr.on('data', chunk => { failures += chunk })
    children.push(child)
    return child
  }
  async function metadata() {
    const manifest = path.join(root, 'manifest.json')
    const child = spawn(process.execPath, [
      '--import=' + path.join(root, 'webtorrent-bootstrap.mjs'), path.join(root, 'metadata.mjs'),
      wrapper, `magnet:?xt=urn:btih:${parsed.infoHash}`, manifest, path.join(root, 'metadata-scratch'), saved
    ], { stdio: ['ignore', 'ignore', 'pipe'] })
    children.push(child)
    child.stderr.on('data', chunk => { failures += chunk })
    return until(() => readJSON(manifest), 'Cached metadata did not resolve')
  }
  async function selections() {
    try { return (await fs.readFile(eventsPath, 'utf8')).trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) } catch { return [] }
  }
  return { root, parsed, payloads, saved, select, ready, launch, stop, selections, metadata,
    stopServing: () => { serveData = false }, requests: () => requests }
}

test('active file downloads first; other videos follow; saved torrent reopens offline', { timeout: 30000 }, async t => {
  const f = await fixture(t)
  await f.select('episode10.mp4', 'first')
  const child = f.launch()
  await f.ready('first')
  const folder = path.join(f.saved, f.parsed.infoHash, 'series')
  await until(async () => {
    try { return (await fs.readFile(path.join(folder, 'episode2.mp4'))).equals(f.payloads.get('episode2.mp4')) } catch { return false }
  }, 'Remaining video did not finish')
  const selections = await f.selections()
  assert.equal(selections[0].name, 'episode10.mp4')
  assert.equal(selections[1].name, 'episode2.mp4')
  assert.ok(selections[1].done.includes('episode10.mp4'), 'Background video competed with active download')
  assert.ok(f.requests().every(name => name !== 'readme.txt'), 'Non-media extra downloaded')
  await f.stop(child)
  for (const name of ['episode2.mp4', 'episode10.mp4']) {
    assert.ok((await fs.readFile(path.join(folder, name))).equals(f.payloads.get(name)), 'Saved file changed on shutdown')
  }
  f.stopServing()
  assert.equal((await f.metadata()).files.length, 3)
  await f.select('episode10.mp4', 'reopened')
  f.launch(`magnet:?xt=urn:btih:${f.parsed.infoHash}`)
  const response = await f.ready('reopened')
  const data = Buffer.from(await (await fetch(response.url)).arrayBuffer())
  assert.ok(data.equals(f.payloads.get('episode10.mp4')), 'Saved file could not play without peers or metadata network access')
})

test('switching videos reprioritizes the same running torrent client', { timeout: 30000 }, async t => {
  const f = await fixture(t, 2 * 1024 * 1024)
  await f.select('episode2.mp4', 'before')
  const child = f.launch()
  const before = await f.ready('before')
  await f.select('episode10.mp4', 'after')
  const after = await f.ready('after')
  assert.equal(child.exitCode, null)
  assert.equal(new URL(before.url).port, new URL(after.url).port)
  // Stream URLs are index-based (/<infoHash>/<index>) so release names with
  // `+`, `#`, `?`, `&`, spaces, or brackets can never 404. Resolve the index
  // back to the torrent file table instead of matching a filename suffix.
  for (const [response, expected] of [[before, 'episode2.mp4'], [after, 'episode10.mp4']]) {
    const parts = new URL(response.url).pathname.split('/').filter(Boolean)
    assert.equal(parts.length, 2)
    assert.equal(parts[0].toLowerCase(), f.parsed.infoHash.toLowerCase())
    assert.ok(/^\d+$/.test(parts[1]), `Stream URL is not index-based: ${response.url}`)
    assert.equal(path.basename(f.parsed.files[Number(parts[1])].path), expected)
  }
  const selections = await f.selections()
  assert.equal(selections[0].name, 'episode2.mp4')
  assert.equal(selections[1].name, 'episode10.mp4')
  assert.ok(!selections[1].done.includes('episode2.mp4'), 'Fixture completed before priority switch could be tested')
})

test('serves files with URL-hostile names without 404', { timeout: 30000 }, async t => {
  // Regression for nyaa.si/view/1996097
  // (`... WEBRip DD+ x265-EMBER/S02E01-... [XXX].mkv`): the previous runtime
  // built `/:infoHash/:path` URLs with encodeURIComponent, but WebTorrent's
  // server decodes with decodeURI, which leaves %2B/%23/%3F/%26/... encoded.
  // Every path containing `+`, `#`, `?`, `&`, ... 404d and mpv reported
  // "Loading failed". Index URLs (`/:infoHash/:index`) contain only hex and
  // digits and are immune to all filename-encoding mismatches.
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'macmpv-torrent-hostile-'))
  const children = []
  let failures = ''
  t.after(async () => {
    for (const child of children) {
      if (child.exitCode !== null || child.signalCode !== null) continue
      await new Promise(resolve => {
        child.once('exit', resolve)
        child.kill('SIGTERM')
        const timer = setTimeout(() => child.kill('SIGKILL'), 2500)
        timer.unref()
        child.once('exit', () => clearTimeout(timer))
      })
    }
    await fs.rm(root, { recursive: true, force: true })
  })
  const folder = 'The Apothecary Diaries S02 1080p Dual Audio WEBRip DD+ x265-EMBER'
  const payloads = new Map([
    [`${folder}/S02E01-Maomao and Maomao [F878C427].mp4`, Buffer.alloc(64 * 1024, 11)],
    [`${folder}/S02E02-Caravan #1 & Friends; Part 2, dub=jp@flac.mp4`, Buffer.alloc(64 * 1024, 22)],
    [`${folder}/episode-special [日本語].mp4`, Buffer.alloc(64 * 1024, 33)]
  ])
  const staging = path.join(root, 'staging')
  for (const [rel, data] of payloads) {
    await fs.mkdir(path.dirname(path.join(staging, rel)), { recursive: true })
    await fs.writeFile(path.join(staging, rel), data)
  }
  const bytes = await new Promise((resolve, reject) => createTorrent(
    path.join(staging, folder),
    { pieceLength: 16384, announceList: [] },
    (error, result) => error ? reject(error) : resolve(result)
  ))
  const parsed = await parseTorrent(bytes)
  // Pre-seed the durable download dir so the runtime serves fully verified
  // files with no peers, as after a persisted download is reopened offline.
  const saved = path.join(root, 'saved')
  for (const [rel, data] of payloads) {
    const dest = path.join(saved, parsed.infoHash, rel)
    await fs.mkdir(path.dirname(dest), { recursive: true })
    await fs.writeFile(dest, data)
  }
  // The runtime resolves magnets offline via the cached `.torrent`; without
  // it a DHT-disabled client could never reach `ready` and no URL is emitted.
  await fs.mkdir(path.join(saved, '.metadata'), { recursive: true })
  await fs.writeFile(path.join(saved, '.metadata', `${parsed.infoHash}.torrent`), bytes)
  const source = await fs.readFile(path.join(project, 'Sources/Cinewave/TorrentDownloadRuntime.swift'), 'utf8')
  const runtime = /static let script = #"""\n([\s\S]*?)\n    """#/.exec(source)[1].split('\n').map(line => line.slice(4)).join('\n')
  await fs.writeFile(path.join(root, 'runtime.mjs'), runtime)
  const swift = await fs.readFile(path.join(project, 'Sources/Cinewave/MagnetStream.swift'), 'utf8')
  for (const [variable, name] of [['bootstrap', 'webtorrent-bootstrap.mjs'], ['loader', 'webtorrent-loader.mjs']]) {
    const embedded = new RegExp(`let ${variable} = """\\n([\\s\\S]*?)\\n        """`).exec(swift)[1]
    await fs.writeFile(path.join(root, name), embedded.split('\n').map(line => line.slice(8)).join('\n'))
  }
  await fs.symlink(path.dirname(path.dirname(modulePath)), path.join(root, 'node_modules'))
  const wrapper = path.join(root, 'wrapper.mjs')
  await fs.writeFile(wrapper, `
    import WebTorrent from ${JSON.stringify(pathToFileURL(modulePath).href)};
    export default class extends WebTorrent {
      constructor(opts) { super({...opts, dht:false, tracker:false, lsd:false, natUpnp:false, natPmp:false, utp:false}); }
    }
  `)
  const output = path.join(root, 'stream.json')
  const control = path.join(root, 'selection.json')
  async function select(rel, requestID) {
    const index = parsed.files.findIndex(file => file.path.replace(/\\/g, '/') === rel)
    assert.ok(index >= 0, `fixture file missing from torrent: ${rel}`)
    await fs.writeFile(control + '.tmp', JSON.stringify({ index, requestID }))
    await fs.rename(control + '.tmp', control)
  }
  async function ready(requestID) {
    return until(async () => {
      const response = await readJSON(output)
      return response?.requestID === requestID ? response : false
    }, 'No stream response: ' + failures)
  }
  const rels = [...payloads.keys()]
  await select(rels[0], 'first')
  const child = spawn(process.execPath, [
    '--import=' + path.join(root, 'webtorrent-bootstrap.mjs'), path.join(root, 'runtime.mjs'),
    wrapper, `magnet:?xt=urn:btih:${parsed.infoHash}`, saved, output, control, JSON.stringify(['mp4'])
  ], { stdio: ['ignore', 'ignore', 'pipe'] })
  child.stderr.on('data', chunk => { failures += chunk })
  children.push(child)
  // Switch through every hostile file on the same running client, fetching
  // full bodies, ranges, and HEAD each time.
  for (let i = 0; i < rels.length; i++) {
    const rel = rels[i]
    const id = i === 0 ? 'first' : `req-${i}`
    if (i > 0) await select(rel, id)
    const response = await ready(id)
    assert.match(response.url, /^http:\/\/127\.0\.0\.1:\d+\/[a-f0-9]{40}\/\d+$/i)
    assert.ok(!response.url.includes('%'), `URL must not percent-encode filenames: ${response.url}`)
    assert.ok(!response.url.includes('.mp4'), `URL must not embed filenames: ${response.url}`)
    const parts = new URL(response.url).pathname.split('/').filter(Boolean)
    assert.equal(parts[0].toLowerCase(), parsed.infoHash.toLowerCase())
    const served = parsed.files[Number(parts[1])].path.replace(/\\/g, '/')
    assert.equal(served, rel)
    const expected = payloads.get(rel)
    const full = await fetch(response.url)
    assert.equal(full.status, 200)
    assert.ok(Buffer.from(await full.arrayBuffer()).equals(expected), `full body mismatch for ${rel}`)
    const ranged = await fetch(response.url, { headers: { Range: 'bytes=0-99' } })
    assert.equal(ranged.status, 206)
    assert.equal(ranged.headers.get('content-range'), `bytes 0-99/${expected.length}`)
    assert.ok(Buffer.from(await ranged.arrayBuffer()).equals(expected.subarray(0, 100)), `range mismatch for ${rel}`)
    const head = await fetch(response.url, { method: 'HEAD' })
    assert.equal(head.status, 200)
    assert.equal(Number(head.headers.get('content-length')), expected.length)
  }
  assert.equal(child.exitCode, null)
})
