import test from 'node:test'
import assert from 'node:assert/strict'
import { authorIndex, sharedPublications } from '../../docs/src/components/kbCoauthors.ts'

test('ORCID joins spellings, separates namesakes, and leaves an unidentified byline separate', () => {
  const uri = 'https://orcid.org/0000-0002-1694-233X', other = 'https://orcid.org/0000-0002-1825-0097'
  const sign = (name, orcid = null) => ({ name, orcid, key: 'lee|a' })
  const a = sign('A. Lee', uri), alias = sign('Alex Lee', uri), b = sign('A. Lee', other), unknown = sign('A. Lee')
  const papers = [[a, b, a], [alias, b], [unknown, b]].map((authors, i) => ({ id: String(i), title: 'Example', published: '', authors }))
  const { people, aliases } = authorIndex(papers)
  assert.equal(people.size, 3)
  assert.equal(aliases.get('lee|a').size, 3)
  const person = people.get('orcid:0000-0002-1694-233X')
  assert.deepEqual([...person.names], ['A. Lee', 'Alex Lee'])
  assert.deepEqual(person.papers.map(p => p.id), ['0', '1'])
  const [edge] = sharedPublications(person, people)
  assert.equal(edge.person.orcid, other)
  assert.deepEqual(edge.papers.map(p => p.id), ['0', '1'])
})
