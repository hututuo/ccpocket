function lineAndColumn(text, offset) {
  let line = 1;
  let column = 1;
  for (let index = 0; index < offset; index += 1) {
    if (text[index] === '\n') {
      line += 1;
      column = 1;
    } else {
      column += 1;
    }
  }
  return {line, column};
}

function childPath(parent, key) {
  if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) return `${parent}.${key}`;
  return `${parent}[${JSON.stringify(key)}]`;
}

class DuplicateKeyScanner {
  constructor(text, filename, label) {
    this.text = text;
    this.filename = filename;
    this.label = label;
    this.index = 0;
  }

  scan() {
    this.skipWhitespace();
    this.scanValue('$');
    this.skipWhitespace();
    if (this.index !== this.text.length) this.invalid();
  }

  invalid() {
    throw new Error(`${this.label}: invalid JSON in ${this.filename}`);
  }

  duplicate(path, offset) {
    const {line, column} = lineAndColumn(this.text, offset);
    throw new Error(
      `${this.label}: duplicate object key in ${this.filename} at ${path} ` +
      `(line ${line}, column ${column})`,
    );
  }

  skipWhitespace() {
    while (/\s/.test(this.text[this.index] ?? '')) this.index += 1;
  }

  expect(character) {
    if (this.text[this.index] !== character) this.invalid();
    this.index += 1;
  }

  scanValue(path) {
    this.skipWhitespace();
    switch (this.text[this.index]) {
      case '{':
        this.scanObject(path);
        return;
      case '[':
        this.scanArray(path);
        return;
      case '"':
        this.scanString();
        return;
      default:
        this.scanPrimitive();
    }
  }

  scanObject(path) {
    this.expect('{');
    this.skipWhitespace();
    if (this.text[this.index] === '}') {
      this.index += 1;
      return;
    }
    const keys = new Set();
    while (this.index < this.text.length) {
      this.skipWhitespace();
      const keyOffset = this.index;
      const key = this.scanString();
      if (keys.has(key)) this.duplicate(path, keyOffset);
      keys.add(key);
      this.skipWhitespace();
      this.expect(':');
      this.scanValue(childPath(path, key));
      this.skipWhitespace();
      if (this.text[this.index] === '}') {
        this.index += 1;
        return;
      }
      this.expect(',');
    }
    this.invalid();
  }

  scanArray(path) {
    this.expect('[');
    this.skipWhitespace();
    if (this.text[this.index] === ']') {
      this.index += 1;
      return;
    }
    let entryIndex = 0;
    while (this.index < this.text.length) {
      this.scanValue(`${path}[${entryIndex}]`);
      entryIndex += 1;
      this.skipWhitespace();
      if (this.text[this.index] === ']') {
        this.index += 1;
        return;
      }
      this.expect(',');
    }
    this.invalid();
  }

  scanString() {
    const start = this.index;
    this.expect('"');
    while (this.index < this.text.length) {
      const character = this.text[this.index];
      this.index += 1;
      if (character === '"') {
        return JSON.parse(this.text.slice(start, this.index));
      }
      if (character === '\\') {
        if (this.text[this.index] === 'u') this.index += 5;
        else this.index += 1;
      }
    }
    this.invalid();
  }

  scanPrimitive() {
    const start = this.index;
    while (this.index < this.text.length && !/[\s,}\]]/.test(this.text[this.index])) {
      this.index += 1;
    }
    if (this.index === start) this.invalid();
  }
}

export function parseStrictJson(text, {filename, label}) {
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error(`${label}: invalid JSON in ${filename}`);
  }
  new DuplicateKeyScanner(text, filename, label).scan();
  return value;
}
