// Focus management for modal dialogs: trap Tab within the open modal so keyboard
// focus can't escape to the page behind it, and restore focus to wherever it was
// when the modal closes. One trap is active at a time (only one modal opens at once).

let active = null;

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), ' +
  'select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

function focusables(root) {
  return Array.from(root.querySelectorAll(FOCUSABLE)).filter(
    (el) => el.offsetParent !== null,
  );
}

export function trapFocus(selector) {
  releaseFocus();
  // Defer so the modal is in the DOM (it renders after this update's effects fire).
  requestAnimationFrame(() => {
    const modal = document.querySelector(selector);
    if (!modal) return;
    const previous = document.activeElement;
    const onKeydown = (event) => {
      if (event.key !== "Tab") return;
      const items = focusables(modal);
      if (items.length === 0) return;
      const first = items[0];
      const last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    modal.addEventListener("keydown", onKeydown);
    active = { modal, onKeydown, previous };
    // Focus the modal itself; fields may still be loading, so the first Tab moves
    // into the first field once it renders.
    modal.focus();
  });
}

// Focus the first focusable element within `selector` (the step's form region), so
// entering a step lands the caret in the first field rather than the step rail.
export function focusFirst(selector) {
  requestAnimationFrame(() => {
    const root = document.querySelector(selector);
    if (!root) return;
    const items = focusables(root);
    if (items.length > 0) items[0].focus();
  });
}

export function releaseFocus() {
  if (!active) return;
  active.modal.removeEventListener("keydown", active.onKeydown);
  if (active.previous && typeof active.previous.focus === "function") {
    active.previous.focus();
  }
  active = null;
}
