import { LogoMark } from "./Icons";

export const REPO_URL = "https://github.com/shreyas0917/reelops";

export function TopBar() {
  return (
    <header className="topbar">
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <div className="topbar__inner">
        <a className="brand" href="/" aria-label="ReelOps home">
          <LogoMark />
          <span>ReelOps</span>
        </a>
        <nav aria-label="Site">
          <ul className="topbar__links">
            <li>
              <a href="#how-it-works">How it works</a>
            </li>
            <li>
              <a href={REPO_URL} target="_blank" rel="noreferrer">
                {/* nbsp: the link is a flex container, which drops a plain trailing space */}
                <span className="wide-only">Source on{"\u00a0"}</span>GitHub
              </a>
            </li>
          </ul>
        </nav>
      </div>
    </header>
  );
}
