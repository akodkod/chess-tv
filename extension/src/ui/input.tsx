import type { ComponentProps } from "react"
import { twMerge } from "tailwind-merge"
export function Input({ className, ...props }: ComponentProps<"input">) {
  return (
    <input
      className={twMerge(
        "h-11 w-full rounded-md border border-stone-300 bg-white px-3 text-base shadow-xs outline-none focus-visible:border-emerald-700 focus-visible:ring-2 focus-visible:ring-emerald-700/20 disabled:opacity-50",
        className,
      )}
      {...props}
    />
  )
}
