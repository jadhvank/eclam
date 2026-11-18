// Electric Clam managed omp hook v1
// Installed as ~/.omp/agent/extensions/electric-clam.ts; restart omp to load.
export default function (pi) {
    const hookBinary = __ECLAM_HOOK_BINARY__;
    // State belongs to this factory invocation, including each child session.
    let running = false;
    let pending = false;
    let timer;
    let context;

    async function pulse() {
        if (!running || pending) return;
        pending = true;
        try {
            // Direct argv, no shell interpolation. A removed app is a no-op.
            await pi.exec(hookBinary, ["omp"], { timeout: 1000 });
        } catch {
            // Never fail an agent turn because the optional signal is unavailable.
        } finally {
            pending = false;
        }
    }

    function stop() {
        running = false;
        if (timer !== undefined) context.clearTimer(timer);
        timer = undefined;
    }

    pi.on("agent_start", (_event, ctx) => {
        stop();
        context = ctx;
        running = true;
        void pulse();
        // Below eclam's 30-second hook grace, including during long tool calls.
        timer = ctx.setInterval(pulse, 10_000);
    });
    pi.on("agent_end", stop);
    pi.on("session_switch", stop);
    pi.on("session_shutdown", stop);
}
