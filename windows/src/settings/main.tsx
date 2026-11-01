import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { AppRuntime } from "./runtime";
import "./styles.css";

const root = createRoot(document.getElementById("root")!);

AppRuntime.start().then(
  (runtime) =>
    root.render(
      <StrictMode>
        <App runtime={runtime} />
      </StrictMode>,
    ),
  (error: unknown) => {
    console.error("HibiVo failed to start", error);
    root.render(<p className="fatal">HibiVo を起動できませんでした: {String(error)}</p>);
  },
);
