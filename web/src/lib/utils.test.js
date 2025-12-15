import { describe, it, expect } from 'vitest';
import {
  escapeHtml,
  sanitizeHtml,
  formatNumber,
  formatBytes,
  formatTimestamp,
  formatTime,
  formatUptime,
  getLevelColor,
  debounce,
  throttle,
  highlightText,
  highlightPattern,
} from './utils.js';

describe('escapeHtml', () => {
  it('escapes HTML special characters', () => {
    expect(escapeHtml('<script>alert("xss")</script>')).toBe(
      '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
    );
  });

  it('escapes ampersands', () => {
    expect(escapeHtml('foo & bar')).toBe('foo &amp; bar');
  });

  it('escapes single quotes', () => {
    expect(escapeHtml('it\'s')).toBe('it&#039;s');
  });

  it('handles empty string', () => {
    expect(escapeHtml('')).toBe('');
  });

  it('handles null and undefined', () => {
    expect(escapeHtml(null)).toBe('');
    expect(escapeHtml(undefined)).toBe('');
  });
});

describe('sanitizeHtml', () => {
  it('allows span tags with classes', () => {
    const input = '<span class="test">content</span>';
    const result = sanitizeHtml(input);
    expect(result).toContain('<span class="test">');
    expect(result).toContain('</span>');
  });

  it('handles empty input', () => {
    expect(sanitizeHtml('')).toBe('');
    expect(sanitizeHtml(null)).toBe('');
  });
});

describe('formatNumber', () => {
  it('formats numbers with K suffix', () => {
    expect(formatNumber(1000)).toBe('1.0K');
    expect(formatNumber(1500)).toBe('1.5K');
    expect(formatNumber(999999)).toBe('1000.0K');
  });

  it('formats numbers with M suffix', () => {
    expect(formatNumber(1000000)).toBe('1.0M');
    expect(formatNumber(2500000)).toBe('2.5M');
  });

  it('formats small numbers with locale string', () => {
    // Uses toLocaleString() for small numbers
    expect(formatNumber(100)).toBe('100');
    expect(formatNumber(999)).toBe('999');
  });

  it('handles zero and falsy values', () => {
    expect(formatNumber(0)).toBe('0');
    expect(formatNumber(null)).toBe('0');
    expect(formatNumber(undefined)).toBe('0');
  });
});

describe('formatBytes', () => {
  it('formats zero bytes', () => {
    expect(formatBytes(0)).toBe('0 B');
    expect(formatBytes(null)).toBe('0 B');
  });

  it('formats bytes with decimal', () => {
    // Always uses toFixed(1)
    expect(formatBytes(500)).toBe('500.0 B');
    expect(formatBytes(1)).toBe('1.0 B');
  });

  it('formats kilobytes', () => {
    expect(formatBytes(1024)).toBe('1.0 KB');
    expect(formatBytes(1536)).toBe('1.5 KB');
  });

  it('formats megabytes', () => {
    expect(formatBytes(1048576)).toBe('1.0 MB');
  });

  it('formats gigabytes', () => {
    expect(formatBytes(1073741824)).toBe('1.0 GB');
  });
});

describe('formatTime', () => {
  it('formats Date object to time string', () => {
    const date = new Date('2025-01-15T14:30:45');
    const result = formatTime(date);
    // Returns toLocaleTimeString() which varies by locale
    expect(result).toBeTruthy();
    expect(result).not.toBe('-');
  });

  it('returns dash for null/undefined', () => {
    expect(formatTime(null)).toBe('-');
    expect(formatTime(undefined)).toBe('-');
  });
});

describe('formatTimestamp', () => {
  it('formats timestamp to HH:MM:SS', () => {
    const result = formatTimestamp('2025-01-15T14:30:45Z');
    // Returns 24-hour format time
    expect(result).toMatch(/\d{2}:\d{2}:\d{2}/);
  });

  it('handles empty input', () => {
    expect(formatTimestamp('')).toBe('');
    expect(formatTimestamp(null)).toBe('');
  });
});

describe('formatUptime', () => {
  it('formats uptime with days, hours, minutes (no seconds)', () => {
    // 90061 seconds = 1d 1h 1m 1s, but function only shows d/h/m
    const result = formatUptime(90061);
    expect(result).toContain('1d');
    expect(result).toContain('1h');
    expect(result).toContain('1m');
    expect(result).not.toContain('1s'); // seconds not shown
  });

  it('formats hours and minutes', () => {
    const result = formatUptime(3660); // 1h 1m
    expect(result).toBe('1h 1m');
  });

  it('formats minutes only', () => {
    expect(formatUptime(120)).toBe('2m');
    expect(formatUptime(60)).toBe('1m');
  });

  it('returns "< 1m" for small values', () => {
    expect(formatUptime(30)).toBe('< 1m');
    expect(formatUptime(1)).toBe('< 1m');
  });

  it('handles zero and falsy values', () => {
    expect(formatUptime(0)).toBe('0s');
    expect(formatUptime(null)).toBe('0s');
    expect(formatUptime(undefined)).toBe('0s');
  });
});

describe('getLevelColor', () => {
  it('returns red for error levels (uppercase only)', () => {
    expect(getLevelColor('ERROR')).toBe('#f85149');
    expect(getLevelColor('CRITICAL')).toBe('#f85149');
    expect(getLevelColor('ALERT')).toBe('#f85149');
    expect(getLevelColor('EMERGENCY')).toBe('#f85149');
  });

  it('returns orange for WARNING', () => {
    expect(getLevelColor('WARNING')).toBe('#d29922');
  });

  it('returns blue for NOTICE', () => {
    expect(getLevelColor('NOTICE')).toBe('#58a6ff');
  });

  it('returns green for INFO', () => {
    expect(getLevelColor('INFO')).toBe('#3fb950');
  });

  it('returns gray for DEBUG', () => {
    expect(getLevelColor('DEBUG')).toBe('#8b949e');
  });

  it('returns darker gray for TRACE', () => {
    expect(getLevelColor('TRACE')).toBe('#6e7681');
  });

  it('returns default gray for unknown levels', () => {
    expect(getLevelColor('UNKNOWN')).toBe('#8b949e');
    expect(getLevelColor('error')).toBe('#8b949e'); // lowercase returns default
  });
});

describe('highlightText', () => {
  it('highlights search term with mark tag', () => {
    const result = highlightText('Hello World', 'World');
    expect(result).toContain('<mark class="search-highlight">World</mark>');
  });

  it('escapes HTML in text', () => {
    const result = highlightText('<script>alert(1)</script>', 'script');
    expect(result).toContain('&lt;');
    expect(result).toContain('&gt;');
    expect(result).toContain('<mark class="search-highlight">script</mark>');
  });

  it('returns escaped text when no search term', () => {
    expect(highlightText('Hello World', '')).toBe('Hello World');
    expect(highlightText('Hello World', null)).toBe('Hello World');
  });

  it('handles case-insensitive search', () => {
    const result = highlightText('Hello World', 'world');
    expect(result).toContain('search-highlight');
  });

  it('handles empty text', () => {
    expect(highlightText('', 'test')).toBe('');
    expect(highlightText(null, 'test')).toBe('');
  });
});

describe('highlightPattern', () => {
  it('highlights UUID placeholder', () => {
    const result = highlightPattern('Request <UUID> failed');
    expect(result).toContain('<span class="placeholder uuid">');
  });

  it('highlights IP placeholder', () => {
    const result = highlightPattern('From <IP>');
    expect(result).toContain('<span class="placeholder ip">');
  });

  it('highlights NUM placeholder', () => {
    const result = highlightPattern('Count: <NUM>');
    expect(result).toContain('<span class="placeholder num">');
  });

  it('handles empty input', () => {
    expect(highlightPattern('')).toBe('');
    expect(highlightPattern(null)).toBe('');
  });
});

describe('debounce', () => {
  it('delays function execution', async () => {
    let callCount = 0;
    const fn = () => callCount++;
    const debounced = debounce(fn, 50);

    debounced();
    debounced();
    debounced();

    expect(callCount).toBe(0);

    await new Promise(resolve => setTimeout(resolve, 100));

    expect(callCount).toBe(1);
  });
});

describe('throttle', () => {
  it('executes immediately on first call', () => {
    let callCount = 0;
    const fn = () => callCount++;
    const throttled = throttle(fn, 50, 'test1');

    throttled();
    expect(callCount).toBe(1);
  });

  it('throttles subsequent calls', async () => {
    let callCount = 0;
    const fn = () => callCount++;
    const throttled = throttle(fn, 50, 'test2');

    throttled();
    throttled();
    throttled();

    expect(callCount).toBe(1);

    await new Promise(resolve => setTimeout(resolve, 100));
    throttled();

    expect(callCount).toBe(2);
  });
});
