import { cva, type VariantProps } from "class-variance-authority"
import { clsx } from "clsx"
// shadcn/ui-style native Button: only the variants used by this popup.
import type { ComponentProps } from "react"
import { twMerge } from "tailwind-merge"
const variants = cva(
  "inline-flex h-10 items-center justify-center rounded-md px-4 text-sm font-medium transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-700 disabled:pointer-events-none disabled:opacity-45",
  {
    variants: {
      variant: {
        default: "bg-emerald-800 text-white hover:bg-emerald-900",
        outline: "border border-stone-300 bg-white text-stone-800 hover:bg-stone-100",
        ghost: "text-stone-600 hover:bg-stone-100",
      },
    },
    defaultVariants: { variant: "default" },
  },
)
export function Button({
  className,
  variant,
  ...props
}: ComponentProps<"button"> & VariantProps<typeof variants>) {
  return (
    <button
      className={twMerge(clsx(variants({ variant }), className))}
      {...props}
    />
  )
}
