// An unidentified byline only matches the same spelling. Never acquire an ORCID by matching names.
export type Byline = { name: string; key: string; orcid: string | null; position: number }
export type Publication = { id: string; title: string; published: string; authors: Byline[] }
export type Profile = { id: string; name: string; orcid: string | null; names: Set<string>; papers: Publication[] }

export const identity = (a: Byline) => a.orcid ? 'orcid:' + a.orcid.slice(a.orcid.lastIndexOf('/') + 1) : 'name:' + a.name

export function authorIndex(papers: Publication[]) {
  const people = new Map<string, Profile>()
  const aliases = new Map<string, Set<string>>()
  for (const paper of papers) {
    const seen = new Set<string>()
    for (const a of paper.authors) {
      const id = identity(a)
      let person = people.get(id)
      if (!person) {
        person = { id, name: a.name, orcid: a.orcid, names: new Set(), papers: [] }
        people.set(id, person)
      }
      person.names.add(a.name)
      if (a.name.length > person.name.length) person.name = a.name
      let keys = aliases.get(a.key)
      if (!keys) aliases.set(a.key, keys = new Set())
      keys.add(id)
      if (!seen.has(id)) person.papers.push(paper)
      seen.add(id)
    }
  }
  return { people, aliases }
}

export function sharedPublications(person: Profile, people: Map<string, Profile>) {
  const shared = new Map<string, Publication[]>()
  for (const paper of person.papers) {
    for (const id of new Set(paper.authors.map(identity))) {
      if (id === person.id) continue
      const papers = shared.get(id)
      if (papers) papers.push(paper)
      else shared.set(id, [paper])
    }
  }
  return Array.from(shared, ([id, papers]) => ({ person: people.get(id)!, papers }))
    .sort((a, b) => b.papers.length - a.papers.length || a.person.name.localeCompare(b.person.name) || a.person.id.localeCompare(b.person.id))
}
