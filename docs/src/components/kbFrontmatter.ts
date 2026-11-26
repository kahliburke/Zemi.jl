// Attached Markdown is user content. Only a leading, delimited YAML mapping supplies metadata.
import { isMap, parseDocument } from 'yaml'

export function readAttachment(source: string, filename: string) {
  const result = { title: filename, date: '', metadata: [] as [string, string][], body: source, unparsed: '' }
  const header = /^\uFEFF?---[^\S\r\n]*\r?\n/.exec(source)
  if (!header) return result
  const rest = source.slice(header[0].length)
  const end = /^(?:---|\.\.\.)[^\S\r\n]*(?:\r?\n|$)/m.exec(rest)
  if (!end) {
    // A horizontal rule may start an ordinary Markdown document. An unclosed metadata
    // mapping, on the other hand, should remain readable exactly as supplied.
    return /^[\w-]+:[ \t]/m.test(rest.split('\n', 1)[0]) ? { ...result, body: '', unparsed: source } : result
  }
  const yaml = rest.slice(0, end.index)
  const body = rest.slice(end.index + end[0].length)
  try {
    const doc = parseDocument(yaml)
    if (doc.errors.length || doc.warnings.length || !isMap(doc.contents)) throw new Error('Invalid metadata')
    const data = doc.toJS({ maxAliasCount: 32 })
    const metadata: [string, string][] = []
    let title = filename, date = ''
    for (const [key, value] of Object.entries(data)) {
      if (key === 'title' && typeof value === 'string' && value.trim()) title = value
      else if (key === 'date' && typeof value === 'string') date = value
      else metadata.push([key, typeof value === 'string' ? value : JSON.stringify(value)])
    }
    return { title, date, metadata, body, unparsed: '' }
  } catch {
    return { ...result, body, unparsed: source.slice(0, header[0].length + end.index + end[0].length) }
  }
}
