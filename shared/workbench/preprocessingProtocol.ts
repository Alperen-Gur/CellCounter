import type { ParameterSpec, ParameterValue } from "./extensionProtocol";

/** Wire recipes contain parameters only. Stable editor keys never enter saved workflows. */
export type PreprocessingRecipeStep = { method: string } & Record<string, ParameterValue>;
export interface PreprocessingDraftStep {
  key: string;
  method: string;
  values: Record<string, ParameterValue>;
}
export interface PreprocessingFilter {
  method: string; name?: string; notes?: string[]; dimensions: number[];
  defaults: Record<string, ParameterValue>; parameterUnits?: Record<string, string>;
  intensityEffect: string;
}
export interface PreprocessingParameterSpec extends ParameterSpec { exclusiveMinimum?: number }
export interface PreprocessingCatalogue {
  engineVersion: string;
  filters: PreprocessingFilter[];
  recipeSchema: { minItems: number; maxItems: number; items: { properties: Record<string, PreprocessingParameterSpec> } };
  notes: string[];
}
export const recipeToDraft = (recipe: PreprocessingRecipeStep[]): PreprocessingDraftStep[] =>
  recipe.map(({ method, ...values }) => ({ key: crypto.randomUUID(), method, values }));
export const recipeFromDraft = (steps: PreprocessingDraftStep[]): PreprocessingRecipeStep[] =>
  steps.map(({ method, values }) => ({ ...values, method }));

export function recipeStepIssues(step: PreprocessingDraftStep, catalogue: PreprocessingCatalogue, dimension: 2 | 3): string[] {
  const filter = catalogue.filters.find((item) => item.method === step.method);
  if (!filter) return ["This filter is unavailable in the current runtime."];
  const issues = filter.dimensions.includes(dimension) ? [] : [`This filter does not support a ${dimension}D source.`];
  const values = { ...filter.defaults, ...step.values };
  for (const [key, value] of Object.entries(values)) {
    const spec = catalogue.recipeSchema.items.properties[key];
    if (!(key in filter.defaults) || !spec) { issues.push(`Unknown parameter: ${key}.`); continue; }
    if ((spec.type === "boolean" && typeof value !== "boolean") ||
      (spec.type === "string" && typeof value !== "string") ||
      ((spec.type === "number" || spec.type === "integer") && (typeof value !== "number" || !Number.isFinite(value) ||
        (spec.type === "integer" && !Number.isInteger(value)))) ||
      (spec.enum && !spec.enum.includes(value))) {
      issues.push(`${spec.title ?? key} has an invalid value.`);
    } else if (typeof value === "number" &&
      ((spec.minimum !== undefined && value < spec.minimum) || (spec.maximum !== undefined && value > spec.maximum) ||
        (spec.exclusiveMinimum !== undefined && value <= spec.exclusiveMinimum))) {
      issues.push(`${spec.title ?? key} is outside its allowed range.`);
    }
  }
  if (step.method === "median" && Number(values.size) % 2 !== 1) issues.push("Median neighborhood size must be odd.");
  if (step.method === "normalize" && Number(values.lowerPercentile) >= Number(values.upperPercentile)) {
    issues.push("The lower percentile must be below the upper percentile.");
  }
  return issues;
}

export function recipeIsValid(steps: PreprocessingDraftStep[], catalogue: PreprocessingCatalogue | undefined, dimension: 2 | 3): boolean {
  return Boolean(catalogue && steps.length >= catalogue.recipeSchema.minItems && steps.length <= catalogue.recipeSchema.maxItems &&
    steps.every((step) => recipeStepIssues(step, catalogue, dimension).length === 0));
}
