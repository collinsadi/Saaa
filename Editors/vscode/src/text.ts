/** A slice that never splits a surrogate pair: half an emoji is invalid Unicode that Saaa's JSON decoder rejects. */
export function safeSlice(text: string, start: number, end: number): string {
  if (end < text.length && end > 0 && isHighSurrogate(text.charCodeAt(end - 1))) end -= 1;
  if (start > 0 && start < text.length && isLowSurrogate(text.charCodeAt(start))) start += 1;
  return text.slice(start, Math.max(start, end));
}

function isHighSurrogate(code: number): boolean {
  return code >= 0xd800 && code <= 0xdbff;
}

function isLowSurrogate(code: number): boolean {
  return code >= 0xdc00 && code <= 0xdfff;
}
