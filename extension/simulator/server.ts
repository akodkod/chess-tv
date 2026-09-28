const result = await Bun.build({
  entrypoints: [import.meta.dir + "/main.ts"],
  target: "browser",
  minify: false,
})
if (!result.success) throw new Error("Simulator build failed", { cause: result.logs })
const script = await result.outputs[0]!.text()
const html = await Bun.file(import.meta.dir + "/index.html").text()
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.SIMULATOR_PORT || 4173),
  fetch(request) {
    const path = new URL(request.url).pathname
    if (path === "/")
      return new Response(html, {
        headers: { "Content-Type": "text/html", "Cache-Control": "no-store" },
      })
    if (path === "/main.js")
      return new Response(script, {
        headers: { "Content-Type": "text/javascript", "Cache-Control": "no-store" },
      })
    return new Response("Not found", { status: 404 })
  },
})
console.log(`Simulator: ${server.url}`)
for (const signal of ["SIGINT", "SIGTERM"] as const)
  process.on(signal, () => {
    void server.stop(true)
    process.exit(0)
  })
