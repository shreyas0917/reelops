const STEPS = [
  { title: "Upload", text: "A narrated screen recording: MP4, MOV or WebM, up to 200 MB." },
  { title: "Transcribe", text: "Whisper turns your narration into timed caption segments." },
  { title: "Caption and voice", text: "Captions are burned in and Amazon Polly re-reads your script, timed to the video." },
  { title: "Download", text: "A finished MP4, ready to share. Videos are kept for 14 days." },
];

export function HowItWorks() {
  return (
    <section id="how-it-works" className="card how" aria-labelledby="how-heading" tabIndex={-1}>
      <h2 id="how-heading" className="card__title">
        How it works
      </h2>
      <ol className="how__steps">
        {STEPS.map((step, i) => (
          <li key={step.title}>
            <span className="how__num" aria-hidden="true">
              {i + 1}
            </span>
            <span>
              <strong>{step.title}</strong>
              <span className="how__text">{step.text}</span>
            </span>
          </li>
        ))}
      </ol>
    </section>
  );
}
