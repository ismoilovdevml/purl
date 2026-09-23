/**
 * Pure histogram helpers: compact counts (shared by the Histogram header and
 * the canvas y-axis) and the canvas bar geometry.
 */

/**
 * Compact a log count for the histogram: 1234 -> '1.2K', 2500000 -> '2.5M'.
 * Unlike formatCount in format.js this always keeps one decimal ('1.0K'),
 * which is what the histogram has always shown.
 * @param {number} num - Non-negative count
 * @returns {string} Compact count
 */
export function formatHistogramCount(num) {
  if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
  if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
  return num.toString();
}

/**
 * Canvas geometry for the histogram: fixed height and padding, bars sized to
 * share the remaining width with a 2px gap between them (never under 2px).
 * @param {number} width - Container width in CSS pixels
 * @param {number} bucketCount - Number of histogram buckets
 * @returns {{ width: number, height: number, padding: { left: number, right: number, top: number, bottom: number }, chartWidth: number, chartHeight: number, barWidth: number, gap: number }}
 */
export function histogramLayout(width, bucketCount) {
  const height = 120; // Increased height for comparison line
  const padding = { left: 50, right: 20, top: 15, bottom: 30 };
  const chartWidth = width - padding.left - padding.right;
  const chartHeight = height - padding.top - padding.bottom;
  const barCount = bucketCount || 1;
  const gap = 2;
  const totalGapWidth = (barCount - 1) * gap;
  const barWidth = Math.max(2, (chartWidth - totalGapWidth) / barCount);
  return { width, height, padding, chartWidth, chartHeight, barWidth, gap };
}
