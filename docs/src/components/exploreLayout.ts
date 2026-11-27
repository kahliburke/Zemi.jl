// The explore page's layout and drawing helpers that need nothing of the page: where the nodes stand
// (on the map in 2D, in the space in 3D), how closely a layout packs them, and the space's sprites.
import type { Node } from './kbExplore'

/** A node as the graph draws it: its place fixed (`fx`…) where the map has one. */
export type GNode = Node & { fx?: number; fy?: number; fz?: number; x?: any; y?: any; z?: any }
export type GLink = { source: string; target: string; kind: string; similarity?: number }
/** How far the map's and the space's coordinates (−1 to 1) are spread in the drawing. */
export const SCALE_2D = 700, SCALE_3D = 360

// How closely a layout packs its documents, as the median distance from one to its nearest, over a
// sample of them.
export function spacing(points: number[][]) {
  if (points.length < 2) return 0
  const step = Math.max(1, Math.floor(points.length / 300)), d: number[] = []
  for (let i = 0; i < points.length; i += step) {
    let least = Infinity
    for (let j = 0; j < points.length; j++) {
      if (j === i) continue
      let s = 0
      for (let k = 0; k < points[i].length; k++) s += (points[i][k] - points[j][k]) ** 2
      if (s < least) least = s
    }
    d.push(Math.sqrt(least))
  }
  d.sort((a, b) => a - b)
  return d[d.length >> 1]
}

// The nodes with no place by meaning (findings, tasks, documents only linked to), fixed where they stand
// among those linked to them, a little aside; those linked to none on a ring just outside the map.
// Every node fixed, nothing drifts once drawn.
export function placeTheRest(nodes: GNode[], links: GLink[], deep: boolean) {
  const at = new Map(nodes.map(n => [n.id, n]))
  const neighbours = new Map<string, string[]>()
  for (const l of links) {
    if (l.kind === 'similar') continue
    neighbours.set(l.source, [...(neighbours.get(l.source) ?? []), l.target])
    neighbours.set(l.target, [...(neighbours.get(l.target) ?? []), l.source])
  }
  const loose = nodes.filter(n => n.fx === undefined)
  const scale = deep ? SCALE_3D : SCALE_2D
  for (let pass = 0; pass < 3; pass++) {                    // those linked only to the unplaced, once those are
    for (const n of loose) {
      if (n.fx !== undefined) continue
      const placed = (neighbours.get(n.id) ?? []).map(id => at.get(id)!).filter(m => m && m.fx !== undefined)
      if (!placed.length) continue
      const mean = (k: 'fx' | 'fy' | 'fz') => placed.reduce((t, m) => t + (m[k] ?? 0), 0) / placed.length
      const turn = hashTurn(n.id), aside = scale * 0.03
      n.fx = mean('fx') + aside * Math.cos(turn); n.fy = mean('fy') + aside * Math.sin(turn)
      if (deep) n.fz = mean('fz') + aside * Math.sin(2 * turn)
    }
  }
  const rest = loose.filter(n => n.fx === undefined)
  rest.forEach((n, i) => {
    const turn = (2 * Math.PI * i) / Math.max(rest.length, 1)
    n.fx = scale * 1.15 * Math.cos(turn); n.fy = scale * 1.15 * Math.sin(turn)
    if (deep) n.fz = 0
  })
}

// A steady angle from an id, so a node stands on the same side of its neighbours each time.
export const hashTurn = (id: string) => [...id].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7) / 0xffffffff * 2 * Math.PI

// Each cluster's middle, from its placed nodes, for its label.
export function clusterCentres(nodes: GNode[], name: (id: number) => string) {
  const sums = new Map<number, { x: number; y: number; z: number; n: number }>()
  for (const n of nodes) {
    if (n.cluster === undefined || n.fx === undefined) continue
    const s = sums.get(n.cluster) ?? { x: 0, y: 0, z: 0, n: 0 }
    s.x += n.fx; s.y += n.fy!; s.z += n.fz ?? 0; s.n++
    sums.set(n.cluster, s)
  }
  return [...sums].filter(([, s]) => s.n >= 3).map(([id, s]) => ({ id, name: name(id), x: s.x / s.n, y: s.y / s.n, z: s.z / s.n, size: s.n }))
}

// A text sprite in the space kept between `least` and `most` pixels tall on screen: smaller with distance
// within that, never too small to read nor growing past `most` as the camera nears it. Set as it is drawn,
// from the camera's distance and the canvas's height.
export function capHeight(sprite: any, least: number, most: number) {
  const base = sprite.scale.clone()
  const at = new (sprite.position.constructor)()
  sprite.onBeforeRender = (renderer: any, _scene: any, camera: any) => {
    const d = camera.position.distanceTo(sprite.getWorldPosition(at))
    const perPixel = 2 * d * Math.tan((camera.fov * Math.PI) / 360) / renderer.domElement.clientHeight
    const px = Math.max(least, Math.min(most, base.y / perPixel))
    sprite.scale.copy(base).multiplyScalar((px * perPixel) / base.y)
    sprite.updateMatrixWorld()
  }
}

// A white disc, lighter at the centre and a little darker towards its antialiased rim, tinted per node.
export function discTexture(THREE: any) {
  const px = 128, c = document.createElement('canvas')
  c.width = c.height = px
  const ctx = c.getContext('2d')!
  const g = ctx.createRadialGradient(px * 0.4, px * 0.38, px * 0.04, px / 2, px / 2, px / 2)
  g.addColorStop(0, '#ffffff'); g.addColorStop(0.7, '#d9d9d9'); g.addColorStop(1, '#b0b0b0')
  ctx.fillStyle = g
  ctx.beginPath(); ctx.arc(px / 2, px / 2, px / 2 - 2, 0, Math.PI * 2); ctx.fill()
  const t = new THREE.CanvasTexture(c)
  t.colorSpace = THREE.SRGBColorSpace
  t.anisotropy = 4
  return t
}

/** How many world units a pixel spans at distance `d` from the camera. */
export const pixelSize = (d: number, renderer: any, camera: any) =>
  2 * d * Math.tan((camera.fov * Math.PI) / 360) / renderer.domElement.clientHeight

/**
 * How far a placed node's nearest other placed node typically is (the median), so the discs can be drawn
 * no wider than leaves most of them apart. Worked out on a grid of cells about a typical spacing wide.
 */
export function measureRoom(nodes: GNode[], deep: boolean) {
  const placed = nodes.filter(n => n.fx !== undefined)
  if (placed.length < 2) return Infinity
  const at = (n: GNode) => [n.fx!, n.fy!, deep ? n.fz ?? 0 : 0]
  const xs = placed.map(at)
  const span = Math.max(...[0, 1, 2].map(a => Math.max(...xs.map(p => p[a])) - Math.min(...xs.map(p => p[a]))))
  const size = Math.max(span / (deep ? Math.cbrt(placed.length) : Math.sqrt(placed.length)), 1e-6)
  const key = (p: number[]) => p.map(v => Math.floor(v / size))
  const grid = new Map<string, number[]>(), rooms: number[] = []
  xs.forEach((p, i) => { const k = key(p).join(); (grid.get(k) ?? grid.set(k, []).get(k)!).push(i) })
  placed.forEach((n, i) => {
    const [cx, cy, cz] = key(xs[i])
    // The cells around it, a ring further out than where the first other one is found (which may be nearer).
    let best = Infinity
    for (let reach = 1; reach <= 6; reach++) {
      const found = best < Infinity
      for (let dx = -reach; dx <= reach; dx++) for (let dy = -reach; dy <= reach; dy++) for (let dz = deep ? -reach : 0; dz <= (deep ? reach : 0); dz++)
        for (const j of grid.get([cx + dx, cy + dy, cz + dz].join()) ?? [])
          if (j !== i) best = Math.min(best, Math.hypot(xs[i][0] - xs[j][0], xs[i][1] - xs[j][1], xs[i][2] - xs[j][2]))
      if (found) break
    }
    rooms.push(best)
  })
  rooms.sort((a, b) => a - b)
  return rooms[rooms.length >> 1]
}
