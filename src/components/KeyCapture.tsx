import { useState, useRef, useEffect } from "react";

interface KeyCaptureProps {
  value: string;
  onChange: (key: string) => void;
  label: string;
}

const MODIFIER_KEYS = new Set([
  "Shift", "Control", "Alt", "Meta",
  "ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight",
  "AltLeft", "AltRight", "MetaLeft", "MetaRight",
]);

const KEY_DISPLAY: Record<string, string> = {
  " ": "Space",
  "ArrowUp": "Up",
  "ArrowDown": "Down",
  "ArrowLeft": "Left",
  "ArrowRight": "Right",
  "Meta": "\u2318",
  "Alt": "\u2325",
  "Control": "Ctrl",
  "Shift": "\u21E7",
};

function formatKey(e: KeyboardEvent): string {
  const parts: string[] = [];
  if (e.metaKey) parts.push("\u2318");
  if (e.ctrlKey) parts.push("Ctrl");
  if (e.altKey) parts.push("\u2325");
  if (e.shiftKey) parts.push("Shift");

  const key = e.key;
  if (!MODIFIER_KEYS.has(key)) {
    const display = KEY_DISPLAY[key] || (key.length === 1 ? key.toUpperCase() : key);
    parts.push(display);
  }
  return parts.join("+");
}

export default function KeyCapture({ value, onChange, label }: KeyCaptureProps) {
  const [capturing, setCapturing] = useState(false);
  const inputRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!capturing) return;

    const handler = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();

      if (e.key === "Escape") {
        setCapturing(false);
        return;
      }
      if (e.key === "Backspace") {
        onChange("");
        setCapturing(false);
        return;
      }
      // Don't capture lone modifiers
      if (MODIFIER_KEYS.has(e.key)) return;

      onChange(formatKey(e));
      setCapturing(false);
    };

    window.addEventListener("keydown", handler, true);
    return () => window.removeEventListener("keydown", handler, true);
  }, [capturing, onChange]);

  return (
    <div className="key-capture">
      <label>{label}</label>
      <button
        ref={inputRef}
        className={`key-capture-btn ${capturing ? "capturing" : ""}`}
        onClick={() => setCapturing(true)}
      >
        {capturing ? "Press a key\u2026" : value || "(none)"}
      </button>
    </div>
  );
}
