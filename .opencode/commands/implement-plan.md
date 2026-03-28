---
description: Implement an approved technical plan from thoughts/tasks/ directory. These plans contain phases with specific changes and success criteria.
---

# Implement Plan

You are tasked with implementing an approved technical plan from `thoughts/tasks/` directory. These plans contain phases with specific changes and success criteria.

## Getting Started

When given a plan path:
- Read the plan completely and check for any existing checkmarks (- [x])
- Read the original ticket and all files mentioned in the plan
- **Read files fully** - never use limit/offset parameters, you need complete context
- Think deeply about how the pieces fit together
- Create a todo list to track your progress
- Start implementing if you understand what needs to be done

If no plan path provided, ask for one.

## Implementation Philosophy

Plans are carefully designed, but reality can be messy. Your job is to:
- Follow the plan's intent while adapting to what you find
- Implement each phase fully before moving to the next
- Verify your work makes sense in the broader codebase context
- Update checkboxes in the plan as you complete sections

When things don't match the plan exactly, think about why and communicate clearly. The plan is your guide, but your judgment matters too.

If you encounter a mismatch:
- STOP and think deeply about why the plan can't be followed
- Present the issue clearly:
  ```
  Issue in Phase [N]:
  Expected: [what the plan says]
  Found: [actual situation]
  Why this matters: [explanation]

  How should I proceed?
  ```

## Verification Approach (TDD Enforced)

After implementing a phase, you MUST follow the TDD cycle and validation:

1. **RED Phase**: Verify tests fail before implementation
   - Run project tests (see AGENTS.md) or run a specific test file
   - Confirm tests fail for the right reasons
   - Document that RED phase is complete

2. **GREEN Phase**: Implement to make tests pass
   - Write minimal implementation
   - Run project tests (see AGENTS.md)
   - Confirm all tests pass

3. **VALIDATE Phase**: Run full validation
   - Run project validation commands (see AGENTS.md)
   - This typically runs: lint, fmt, check, and tests
   - Fix any issues that arise
   - Confirm validation exits with success

4. **Update Progress**:
   - Check off TDD checkboxes in plan (RED, GREEN, VALIDATE)
   - Update your todo list
   - Check off completed items in the plan file using Edit

5. **Commit**: Make a git commit and do not use `--no-verify`, because pre-commit hooks must validate the commit.

6. **Human Approval**: Ask for verification and approval before proceeding to next phase

**IMPORTANT**: You MUST NOT skip the validation step. If validation fails, fix the issues before committing or proceeding.

## If You Get Stuck

When something isn't working as expected:
- First, make sure you've read and understood all the relevant code
- Consider if the codebase has evolved since the plan was written
- Present the mismatch clearly and ask for guidance

Use sub-tasks sparingly - mainly for targeted debugging or exploring unfamiliar territory.

## Resuming Work

If the plan has existing checkmarks:
- Trust that completed work is done
- Pick up from the first unchecked item
- Verify previous work only if something seems off

Remember: You're implementing a solution, not just checking boxes. Keep the end goal in mind and maintain forward momentum.
