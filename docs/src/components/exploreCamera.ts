// The explore page's camera moves: each eases toward its destination with the speed it has, so a new
// destination given during a move bends the move toward it, carrying on from where the view is and how
// fast it is going rather than starting again. One mover serves the map (centre and zoom) and the space
// (camera and the point it looks at), as `read` and `apply` take and set the view.

/** A view as a list of numbers: the map's centre and the log of its zoom, or the space's camera and target. */
export type View = number[]

export function cameraMover(read: () => View | null, apply: (v: View) => void) {
  let goal: View | null = null
  let speed: number[] = []
  let ease = 0.25                                   // seconds: about a quarter of the move's length
  let frame = 0
  let last = 0

  // Critically damped: no overshoot, and a changed goal keeps the speed it has (Game Programming Gems 4, 1.10).
  function step(now: number) {
    const v = read()
    // No view, or one of another kind than the goal (the map became the space): nothing to move.
    if (!goal || !v || v.length !== goal.length) { goal = null; frame = 0; return }
    const dt = Math.min(0.05, (now - last) / 1000 || 0.016)
    last = now
    const w = 2 / ease, x = w * dt, k = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
    let moving = false
    const next = v.map((at, i) => {
      const gap = at - goal![i]
      const t = (speed[i] + w * gap) * dt
      speed[i] = (speed[i] - w * t) * k
      const to = goal![i] + (gap + t) * k
      if (Math.abs(to - goal![i]) > 1e-3 * (1 + Math.abs(goal![i])) || Math.abs(speed[i]) > 1e-3) moving = true
      return to
    })
    apply(moving ? next : goal)
    if (moving) frame = requestAnimationFrame(step)
    else { goal = null; frame = 0 }
  }

  return {
    /** Toward `to` over about `ms`: from where the view is now, at the speed it already has. */
    to(to: View, ms = 900) {
      if (speed.length !== to.length) speed = to.map(() => 0)
      goal = to
      ease = Math.max(0.05, ms / 4000)
      if (!frame) { last = performance.now(); frame = requestAnimationFrame(step) }
    },
    /** Stop where the view is: a person took hold of it. */
    stop() {
      goal = null
      speed = speed.map(() => 0)
      if (frame) cancelAnimationFrame(frame)
      frame = 0
    },
    get moving() { return frame !== 0 },
  }
}
