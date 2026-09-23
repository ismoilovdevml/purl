/**
 * Pure histogram helpers: the canvas bar geometry. Counts are compacted with
 * formatCount from format.js.
 */

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
