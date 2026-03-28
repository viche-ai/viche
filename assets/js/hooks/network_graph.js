export const NetworkGraph = {
  mounted() {
    this.loadD3().then(() => this.initGraph())
    this.handleEvent("graph_update", ({ agents, links }) => {
      this.updateGraph(JSON.parse(agents), JSON.parse(links))
    })
    this.handleEvent("graph_pulse", ({ from, to, color }) => {
      this.animatePulse(from, to, color || "#A7C080")
    })
  },

  loadD3() {
    return new Promise((resolve) => {
      if (window.d3) return resolve()
      const s = document.createElement("script")
      s.src = "https://cdnjs.cloudflare.com/ajax/libs/d3/7.8.5/d3.min.js"
      s.onload = resolve
      document.head.appendChild(s)
    })
  },

  initGraph() {
    const el = this.el
    const agents = JSON.parse(el.dataset.agents || "[]")
    const links = JSON.parse(el.dataset.links || "[]")
    const w = el.clientWidth || 600
    const h = el.clientHeight || 400

    this.svg = d3.select(el).append("svg")
      .attr("width", "100%").attr("height", "100%")
      .attr("viewBox", [0, 0, w, h])

    const style = getComputedStyle(document.documentElement)
    this.borderColor = style.getPropertyValue("--border").trim() || "rgba(255,255,255,0.1)"

    this.simulation = d3.forceSimulation(agents)
      .force("link", d3.forceLink(links).id(d => d.id).distance(150))
      .force("charge", d3.forceManyBody().strength(-600))
      .force("center", d3.forceCenter(w / 2, h / 2))
      .force("collision", d3.forceCollide(40))

    this.linkGroup = this.svg.append("g")
    this.nodeGroup = this.svg.append("g")
    this.pulseGroup = this.svg.append("g")

    this.linkSel = this.linkGroup.selectAll("line").data(links).join("line")
      .attr("stroke", "rgba(255,255,255,0.12)")
      .attr("stroke-width", 1)
      .attr("stroke-dasharray", "6,4")

    const node = this.nodeGroup.selectAll("g").data(agents).join("g")
      .attr("class", "cursor-pointer")
      .call(d3.drag()
        .on("start", (e, d) => { if (!e.active) this.simulation.alphaTarget(0.3).restart(); d.fx = d.x; d.fy = d.y })
        .on("drag", (e, d) => { d.fx = e.x; d.fy = e.y })
        .on("end", (e, d) => { if (!e.active) this.simulation.alphaTarget(0); d.fx = null; d.fy = null }))

    node.append("circle").attr("r", 18).attr("fill", "none")
      .attr("stroke", d => d.color).attr("stroke-width", 1.5).attr("opacity", 0.6)
      .attr("class", "animate-pulse")

    node.append("circle").attr("r", 6).attr("fill", d => d.color)

    node.append("text").text(d => d.name).attr("text-anchor", "middle").attr("dy", 30)
      .attr("fill", "var(--fg-dim, #859289)").attr("font-size", "11px")

    this.nodeSel = node
    this.agents = agents

    this.simulation.on("tick", () => {
      this.linkSel
        .attr("x1", d => d.source.x).attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x).attr("y2", d => d.target.y)
      this.nodeSel.attr("transform", d => `translate(${d.x},${d.y})`)
    })

    this.pulseInterval = setInterval(() => this.triggerRandomPulse(), 1200)
  },

  triggerRandomPulse() {
    const links = this.simulation.force("link").links()
    if (!links.length) return
    const l = links[Math.floor(Math.random() * links.length)]
    const color = l.source.color || "#A7C080"
    this.animatePulse(l.source.id, l.target.id, color)
  },

  animatePulse(fromId, toId, color) {
    const nodes = this.simulation.nodes()
    const src = nodes.find(n => n.id === fromId)
    const tgt = nodes.find(n => n.id === toId)
    if (!src || !tgt) return

    const pulse = this.pulseGroup.append("circle")
      .attr("r", 4).attr("fill", color || "#A7C080")
      .attr("cx", src.x).attr("cy", src.y)

    pulse.transition().duration(900).ease(d3.easeLinear)
      .attr("cx", tgt.x).attr("cy", tgt.y)
      .on("end", () => pulse.remove())
  },

  updateGraph(agents, links) {
    this.simulation.nodes(agents)
    this.simulation.force("link").links(links)
    this.simulation.alpha(0.3).restart()
  },

  destroyed() {
    if (this.pulseInterval) clearInterval(this.pulseInterval)
    if (this.simulation) this.simulation.stop()
  }
}
