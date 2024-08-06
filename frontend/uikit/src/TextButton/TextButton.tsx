import type { ComponentPropsWithoutRef, ReactNode } from "react";

import { forwardRef } from "react";
import { css, cx } from "../../styled-system/css";

export type TextButtonProps = {
  label: ReactNode;
};

export const TextButton = forwardRef<
  HTMLButtonElement,
  ComponentPropsWithoutRef<"button"> & TextButtonProps
>(function TextButton({
  label,
  className,
  ...props
}, ref) {
  const textButtonStyles = useTextButtonStyles();
  return (
    <button
      ref={ref}
      className={cx(
        className,
        textButtonStyles.className,
      )}
      {...props}
    >
      {label}
    </button>
  );
});

export function useTextButtonStyles() {
  const className = css({
    display: "inline-flex",
    alignItems: "center",
    gap: 6,
    fontSize: 16,
    color: "accent",
    borderRadius: 4,
    cursor: "pointer",
    _focusVisible: {
      outline: "2px solid token(colors.focused)",
    },
    _active: {
      translate: "0 1px",
    },
  });

  return {
    className,
  };
}
