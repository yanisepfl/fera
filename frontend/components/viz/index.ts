/**
 * FERA illustrative data-viz - shared, self-contained SVG charts (no chart lib).
 * These show the SHAPE of a mechanism on relative, unlabeled axes - never live
 * on-chain data and never specific returns. See REDESIGN_PLAN.md §3.
 */
export { LpOutcomeChart } from "./LpOutcomeChart";
export { FeeResponseChart } from "./FeeResponseChart";
export { CountUp } from "./CountUp";
export {
  IllustrativeChart,
  LegendChip,
  PrimaryEndpoint,
  HollowEndpoint,
  monotonePath,
  polylineLength,
  CHART_PAD,
  type PlotGeometry,
} from "./IllustrativeChart";
