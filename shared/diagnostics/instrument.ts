import { timeLocalOperation, type LocalOperation } from "./performance";
/** Wrap only explicitly selected async boundaries, binding every method to its real receiver. */
export function instrumentLocalOperations<T extends object>(target: T, operations: Partial<Record<keyof T, LocalOperation>>): T {
  const bound = new Map<PropertyKey, unknown>();
  return new Proxy(target, {
    get(object, property) {
      const value: unknown = Reflect.get(object, property, object);
      if (typeof value !== "function") return value;
      if (!bound.has(property)) {
        const operation = operations[property as keyof T];
        bound.set(property, operation
          ? (...args: unknown[]) => timeLocalOperation(operation, () => Reflect.apply(value, object, args))
          : value.bind(object));
      }
      return bound.get(property);
    },
  });
}
