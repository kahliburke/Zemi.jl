// The calendar's months: weeks from Monday, and stepping across years.
import { test } from 'node:test'
import assert from 'node:assert/strict'
const { shiftMonth, monthWeeks, monthName } = await import('../../docs/src/components/kbCalendar.ts')

test('a month in weeks from Monday', () => {
  const weeks = monthWeeks('2026-10')                        // 1 October 2026 is a Thursday
  assert.deepEqual(weeks[0], [null, null, null, '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04'])
  assert.equal(weeks.at(-1).filter(Boolean).at(-1), '2026-10-31')
  assert.ok(weeks.every(w => w.length === 7))
  assert.equal(monthWeeks('2024-02').flat().filter(Boolean).length, 29)
})

test('months step across years, and are named', () => {
  assert.equal(shiftMonth('2026-12', 1), '2027-01')
  assert.equal(shiftMonth('2026-01', -1), '2025-12')
  assert.equal(monthName('2026-10'), 'October 2026')
})
