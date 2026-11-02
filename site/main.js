// The hero demo and the cleanup mode tabs. No microphone, no network: everything here is a scripted
// replay of a sample from docs/cleanup-modes.md, and the page reads fine without this file.

(() => {
    document.documentElement.classList.add("js");
    setUpDemo();
    setUpTabs();
})();

function setUpDemo() {
    const stage = document.querySelector(".stage");
    const text = document.querySelector(".demo-text");
    const ghost = document.querySelector(".ghost");
    const key = document.querySelector(".key");
    const hud = document.querySelector(".hud");
    const hudLabel = document.querySelector(".hud-label");
    const bars = [...document.querySelectorAll(".bars span")];
    const data = JSON.parse(document.getElementById("demo-data").textContent);
    const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

    const rawText = data.segments.map((s) => s.raw).join("");
    const finalText = data.segments.map((s) => s.final).join("");
    const perCharacter = data.speakMs / rawText.length;
    /** How long a viewer gets to press the key again before the demo stops on its own. */
    const waitForStopMs = 7000;
    const autoStopDelayMs = 700;
    const processingMs = 1100;

    let phase = "done";
    let isAutoplay = false;
    let frame = 0;
    let timer = 0;

    ghost.textContent = rawText;

    const caret = () => {
        const element = document.createElement("span");
        element.className = "caret";
        element.setAttribute("aria-hidden", "true");
        return element;
    };

    function isOnScreen() {
        const box = stage.getBoundingClientRect();
        return box.bottom >= 0 && box.top <= innerHeight;
    }

    function setPhase(next, step) {
        phase = next;
        stage.dataset.phase = next;
        hud.dataset.phase = next;
        stage.dataset.step = step;
        hud.classList.toggle("is-visible", next === "recording" || next === "processing");
        key.setAttribute("aria-label", next === "recording" ? data.labels.stop : data.labels.start);
    }

    function showFinal() {
        text.replaceChildren(finalText, caret());
    }

    /** Lays out the spoken text up to `count` characters, split so the fillers can be crossed out. */
    function showSpoken(count) {
        let left = count;
        const parts = [];
        for (const segment of data.segments) {
            if (left <= 0) break;
            const span = document.createElement("span");
            span.className = segment.final === "" ? "drop" : "keep";
            span.textContent = segment.raw.slice(0, left);
            left -= segment.raw.length;
            parts.push(span);
        }
        text.replaceChildren(...parts, caret());
        const spoken = rawText.slice(0, count);
        hudLabel.textContent = spoken.length > 24 ? `…${spoken.slice(-24)}` : spoken;
    }

    /** Same envelope and wobble as LevelBars in HUDView, driven by a made-up speech level. */
    function animateBars(time) {
        const seconds = time / 1000;
        const level = 0.55 + 0.45 * Math.abs(Math.sin(seconds * 2.3) * Math.sin(seconds * 3.7));
        const weights = [0.3, 0.5, 0.8, 1, 0.8, 0.5, 0.3];
        bars.forEach((bar, index) => {
            const centreness = 1 - Math.abs(index - 3) / 3.5;
            const wobble = Math.sin(seconds * (9 + index * 2.3) + index * 1.7);
            const amplitude = level * weights[index] * (1 + 0.45 * centreness * wobble);
            bar.style.height = `${4 + 20 * Math.min(1, Math.max(0, amplitude))}px`;
        });
    }

    function record() {
        clearTimeout(timer);
        cancelAnimationFrame(frame);
        setPhase("recording", "2");

        if (reducedMotion.matches) {
            showSpoken(rawText.length);
            animateBars(0);
            setPhase("recording", "3");
            timer = setTimeout(stop, waitForStopMs);
            return;
        }

        const started = performance.now();
        let finished = false;
        let shown = -1;
        const tick = (now) => {
            animateBars(now);
            if (!finished) {
                // A frame's timestamp can be earlier than `started`.
                const elapsed = Math.max(0, now - started);
                const count = Math.min(rawText.length, Math.floor(elapsed / perCharacter));
                if (count !== shown) {
                    shown = count;
                    showSpoken(count);
                }
                if (count === rawText.length) {
                    finished = true;
                    setPhase("recording", "3");
                    timer = setTimeout(stop, isAutoplay ? autoStopDelayMs : waitForStopMs);
                }
            }
            frame = requestAnimationFrame(tick);
        };
        frame = requestAnimationFrame(tick);
    }

    function stop() {
        clearTimeout(timer);
        cancelAnimationFrame(frame);
        // Stopping early keeps the demo's point: the rest of the sentence still comes through.
        showSpoken(rawText.length);
        // The spans above are new: without a style flush they start in the processing styles and never fade.
        void text.offsetWidth;
        isAutoplay = false;
        setPhase("processing", "");
        timer = setTimeout(
            () => {
                showFinal();
                setPhase("done", "");
            },
            reducedMotion.matches ? 0 : processingMs,
        );
    }

    function press() {
        if (phase === "processing") return;
        key.classList.add("is-down");
        setTimeout(() => key.classList.remove("is-down"), 130);
        if (phase === "recording") {
            stop();
        } else {
            record();
        }
    }

    key.addEventListener("click", () => {
        isAutoplay = false;
        press();
    });

    // A Mac's right Option is the app's default hotkey, so it works here too. Leaves the event alone:
    // the browser keeps its own shortcuts, and the key only counts while the demo is on screen.
    addEventListener("keydown", (event) => {
        if (event.code !== "AltRight" || event.repeat || !isOnScreen()) return;
        isAutoplay = false;
        press();
    });

    showFinal();
    setPhase("done", "");

    const opensAtTop = scrollY < 80 && !location.hash;
    if (!reducedMotion.matches && opensAtTop) {
        text.replaceChildren(caret());
        stage.dataset.step = "1";
        isAutoplay = true;
        timer = setTimeout(() => {
            if (isOnScreen()) {
                press();
                return;
            }
            // The viewer has scrolled on, and a HUD over what they're reading would only get in the way.
            isAutoplay = false;
            showFinal();
            setPhase("done", "");
        }, 1100);
    }
}

function setUpTabs() {
    const tabs = [...document.querySelectorAll('[role="tab"]')];
    const panels = tabs.map((tab) => document.getElementById(tab.getAttribute("aria-controls")));
    if (tabs.length === 0) return;

    function select(index, focus) {
        tabs.forEach((tab, i) => {
            const selected = i === index;
            tab.setAttribute("aria-selected", String(selected));
            tab.tabIndex = selected ? 0 : -1;
            panels[i].hidden = !selected;
        });
        if (focus) tabs[index].focus();
    }

    tabs.forEach((tab, index) => {
        tab.addEventListener("click", () => select(index, false));
        tab.addEventListener("keydown", (event) => {
            const last = tabs.length - 1;
            const target = {
                ArrowRight: index === last ? 0 : index + 1,
                ArrowLeft: index === 0 ? last : index - 1,
                Home: 0,
                End: last,
            }[event.key];
            if (target === undefined) return;
            event.preventDefault();
            select(target, true);
        });
    });

    document.querySelector(".tabs").hidden = false;
    select(tabs.findIndex((tab) => tab.getAttribute("aria-selected") === "true"), false);
}
