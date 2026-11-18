import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// Import the exact installed source rendered by the Swift installer test.
const source = await readFile(process.argv[2], "utf8");
const { default: install } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);
const flush = async () => { await Promise.resolve(); await Promise.resolve(); };

function host(exec = async () => ({})) {
    const handlers = new Map(), timers = new Map(), calls = [];
    let now = 0, sequence = 0;
    const ctx = {
        setInterval(fn, period) {
            const id = ++sequence;
            timers.set(id, { fn, period, next: now + period });
            return id;
        },
        clearTimer(id) { timers.delete(id); },
    };
    install({
        on(event, handler) { handlers.set(event, handler); },
        exec(command, args, options) {
            calls.push({ command, args, options, at: now });
            return exec();
        },
    });
    return {
        calls, timers,
        async emit(event) { await handlers.get(event)?.({}, ctx); await flush(); },
        async advance(ms) {
            const end = now + ms;
            while (timers.size) {
                const next = Math.min(...[...timers.values()].map(t => t.next));
                if (next > end) break;
                now = next;
                for (const timer of [...timers.values()]) {
                    if (timer.next === now) { timer.next += timer.period; await timer.fn(); }
                }
                await flush();
            }
            now = end;
        },
    };
}

test("signals before the first transcript and throughout a long turn; stops at agent end", async () => {
    const h = host();
    assert.equal(h.calls.length, 0, "loading an idle extension must not hold sleep");
    await h.emit("agent_start");
    assert.equal(h.calls.length, 1);
    assert.equal(h.calls[0].command, "/tmp/App 'quoted' $(literal)/eclam-hook");
    assert.deepEqual(h.calls[0].args, ["omp"]);
    await h.advance(120_000);
    assert.ok(h.calls.length >= 13);
    assert.ok(h.calls.every(c => c.options.timeout <= 2000));
    await h.emit("agent_end");
    const count = h.calls.length;
    await h.advance(120_000);
    assert.equal(h.calls.length, count);
    assert.equal(h.timers.size, 0);
});

test("each child session has independent timers; duplicate starts and shutdown do not leak", async () => {
    const parent = host(), child = host();
    await parent.emit("agent_start");
    await parent.emit("agent_start");
    assert.equal(parent.timers.size, 1);
    await child.emit("agent_start");
    await parent.emit("agent_end");
    await child.advance(30_000);
    assert.ok(child.calls.length >= 4);
    await child.emit("session_switch");
    assert.equal(child.timers.size, 0);
    await child.emit("agent_start");
    await child.emit("session_shutdown");
    assert.equal(child.timers.size, 0);
});

test("missing hook executable and rejected or slow execution never break the agent", async () => {
    const failed = host(async () => { throw new Error("ENOENT"); });
    await failed.emit("agent_start");
    await failed.advance(20_000);
    assert.equal(failed.calls.length, 3);
    await failed.emit("session_shutdown");
    let finish;
    const slow = host(() => new Promise(resolve => { finish = resolve; }));
    await slow.emit("agent_start");
    await slow.advance(30_000);
    assert.equal(slow.calls.length, 1, "do not stack pending subprocesses");
    await slow.emit("agent_end");
    finish({});
    await flush();
    await slow.advance(30_000);
    assert.equal(slow.calls.length, 1);
});
