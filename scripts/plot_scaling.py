"""Plot a load test's scaling.csv as a PNG for the README.

Usage (matplotlib isn't on the host, so run it in a throwaway container):
  docker run --rm -v "$PWD:/w" -w /w python:3.12-slim sh -c \
    "pip install -q matplotlib==3.11.2 && python scripts/plot_scaling.py samples/output/scaling.csv docs/scaling.png"
"""

import csv
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402


def main(csv_path: str, png_path: str) -> None:
    with open(csv_path, newline="") as f:
        rows = list(csv.DictReader(f))
    t = [int(r["elapsed_s"]) / 60 for r in rows]
    visible = [int(r["visible"]) for r in rows]
    in_flight = [int(r["in_flight"]) for r in rows]
    desired = [int(r["desired"]) for r in rows]
    running = [int(r["running"]) for r in rows]

    fig, (top, bottom) = plt.subplots(2, 1, figsize=(9, 5.5), sharex=True, constrained_layout=True)
    fig.suptitle("ReelOps worker autoscaling: 8 jobs, scale from 0 and back to 0")

    top.stackplot(t, visible, in_flight, labels=["waiting (visible)", "in flight"],
                  colors=["#f4a261", "#2a9d8f"], step="post")  # fmt: skip
    top.set_ylabel("jobs (SQS)")
    top.legend(loc="upper right")
    top.grid(alpha=0.3)

    bottom.step(t, desired, where="post", label="desired tasks", color="#264653", linestyle="--")
    bottom.step(t, running, where="post", label="running tasks", color="#e76f51")
    bottom.set_ylabel("worker tasks")
    bottom.set_xlabel("minutes since first upload")
    bottom.set_ylim(-0.2, 3.6)
    bottom.set_yticks([0, 1, 2, 3])
    bottom.legend(loc="upper right")
    bottom.grid(alpha=0.3)

    # Rows not sampled by the script (e.g. reconstructed from ECS/Application
    # Auto Scaling records) are shaded so they can't be mistaken for samples.
    recon = [t[i] for i, r in enumerate(rows) if r.get("source", "sampled") != "sampled"]
    if recon:
        for ax in (top, bottom):
            ax.axvspan(recon[0], t[-1], color="grey", alpha=0.12, lw=0)
        bottom.text(recon[0] + 0.15, 1.8, "reconstructed from\nECS / App Auto Scaling\nrecords",
                    fontsize=8, color="dimgrey", va="center")  # fmt: skip

    fig.savefig(png_path, dpi=120)
    print(f"wrote {png_path} ({len(rows)} samples, {t[-1]:.1f} min)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
