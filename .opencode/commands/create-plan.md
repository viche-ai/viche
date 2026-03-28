---
description: Create detailed implementation plans through an interactive, iterative process. You should be skeptical, thorough, and work collaboratively with the user to produce high-quality technical specifications.
---

# Implementation Plan

You are tasked with creating detailed implementation plans through an interactive, iterative process. You should be skeptical, thorough, and work collaboratively with the user to produce high-quality technical specifications.

## CRITICAL:
- DO NOT do any research, use file specified from the user. If it's not provided, ask the user to provide it.
- DO NOT create any timelines or milestones.
- DO NOT complement choices made by the user: no "Excellent choice", "Great point", or "Very smart", just stick to practical facts and make only relevant observations.

## Initial Response

When this command is invoked:

1. **Check if parameters were provided**:
- If a file path or ticket reference was provided as a parameter, skip the default message
- **FIRST**: Check if a spec file exists (`thoughts/tasks/task-name/spec.md`) and read it FULLY
- Then read the task file and any other provided files FULLY
- Begin the research process

2. **If no parameters provided**, respond with:
```
I'll help you create a detailed implementation plan. Let me start by understanding what we're building.

Please provide:
1. The task/ticket description (or reference to a ticket file)
2. Link to the spec file if it exists (`thoughts/tasks/task-name/spec.md`)
3. Any relevant context, constraints, or specific requirements
4. Links to related research or previous implementations
5. Use the "guided discovery" method

I'll analyze this information and work with you to create a comprehensive plan.

Tip: You can also invoke this command with a spec or task file directly:
- `/create-plan thoughts/tasks/task-name/spec.md`
- `/create-plan thoughts/tasks/task-name/task.md`

For deeper analysis, try: `/create-plan think deeply about thoughts/tasks/task-name/spec.md`
```

3. **"guided discovery" method**
When the "guided discovery" method is selected by the user: Act as a principal engineer using
the "guided discovery" method. Your goal is to help me create a robust technical implementation plan.
- Ask probing, open-ended questions, one at a time.
- Before every question, you should explore the codebase to do research, and consider doing a web search.
- Your questions should force me to think critically about all aspects of the plan.


Then wait for the user's input.

## Process Steps

### Step 1: Context Gathering & Initial Analysis

1. **Read all mentioned files immediately and FULLY**:
   - **FIRST**: Spec file if it exists (`thoughts/tasks/task-name/spec.md`)
   - Ticket/task files (e.g., `thoughts/tasks/task-name/task.md`)
   - Research documents (from `thoughts/research/` or `thoughts/tasks/task-name/research.md`)
   - Related implementation plans (from `thoughts/tasks/*/plan.md`)
   - Any JSON/data files mentioned
   - **IMPORTANT**: Read entire files completely
   - **CRITICAL**: DO NOT spawn sub-tasks before reading these files yourself in the main context
   - **NEVER** read files partially - if a file is mentioned, read it completely

2. **Spawn initial research tasks to gather context**:
   Before asking the user any questions, use specialized agents to research in parallel:

   - Use @codebase-locator to find all files related to the ticket/task
   - Use @codebase-analyzer to understand how the current implementation works
   - If relevant, use @thoughts-locator to find any existing thoughts documents about this feature

   These agents will:
   - Find relevant source files, configs, and tests
   - Identify the specific directories to focus on
   - Trace data flow and key functions
   - Return detailed explanations with file:line references

3. **Read all files identified by research tasks**:
   - After research tasks complete, read ALL files they identified as relevant
   - Read them FULLY into the main context
   - This ensures you have complete understanding before proceeding

4. **Analyze and verify understanding**:
   - Cross-reference the ticket requirements with actual code
   - Identify any discrepancies or misunderstandings
   - Note assumptions that need verification
   - Determine true scope based on codebase reality

5. **Present informed understanding and focused questions**:
   ```
   Based on the ticket and my research of the codebase, I understand we need to [accurate summary].

   I've found that:
   - [Current implementation detail with file:line reference]
   - [Relevant pattern or constraint discovered]
   - [Potential complexity or edge case identified]

   Questions that my research couldn't answer:
   - [Specific technical question that requires human judgment]
   - [Business logic clarification]
   - [Design preference that affects implementation]
   ```

   Only ask questions that you genuinely cannot answer through code investigation.

### Step 2: Research & Discovery

After getting initial clarifications:

1. **If the user corrects any misunderstanding**:
   - DO NOT just accept the correction
   - Spawn new research tasks to verify the correct information
   - Read the specific files/directories they mention
   - Only proceed once you've verified the facts yourself

2. **Create a research todo list** to track exploration tasks

3. **Spawn parallel sub-tasks for comprehensive research**:
   - Create multiple agents to research different aspects concurrently
   - Use the right agent for each type of research:

   **For deeper investigation:**
   - @codebase-locator - To find more specific files
   - @codebase-analyzer - To understand implementation details
   - @codebase-pattern-finder - To find similar features we can model after

   **For historical context:**
   - @thoughts-locator - To find any research, plans, or decisions about this area
   - @thoughts-analyzer - To extract key insights from the most relevant documents

   Each agent knows how to:
   - Find the right files and code patterns
   - Identify conventions and patterns to follow
   - Look for integration points and dependencies
   - Return specific file:line references
   - Find tests and examples

3. **Wait for ALL sub-tasks to complete** before proceeding

4. **Present findings and design options**:
   ```
   Based on my research, here's what I found:

   **Current State:**
   - [Key discovery about existing code]
   - [Pattern or convention to follow]

   **Design Options:**
   1. [Option A] - [pros/cons]
   2. [Option B] - [pros/cons]

   **Open Questions:**
   - [Technical uncertainty]
   - [Design decision needed]

   Which approach aligns best with your vision?
   ```

### Step 3: Plan Structure Development

Once aligned on approach:

1. **Create initial plan outline**:
   ```
   Here's my proposed plan structure:

   ## Overview
   [1-2 sentence summary]

   ## Implementation Phases:
   1. [Phase name] - [what it accomplishes]
   2. [Phase name] - [what it accomplishes]
   3. [Phase name] - [what it accomplishes]

   Does this phasing make sense? Should I adjust the order or granularity?
   ```

2. **Get feedback on structure** before writing details

### Step 4: Detailed Plan Writing

After structure approval:

1. **Write the plan** to `thoughts/tasks/task-name/plan.md` where:
   - `task-name` is the directory matching the task being planned
   - Place the plan in the same directory as the task description
   - Examples:
     - Task: `thoughts/tasks/invoice-error-handling/task.md`
     - Plan: `thoughts/tasks/invoice-error-handling/plan.md`
2. **Use this template structure**:

````markdown
# [Feature/Task Name] Implementation Plan

## Overview

[Brief description of what we're implementing and why]

## Current State Analysis

[What exists now, what's missing, key constraints discovered]

## Desired End State

[A Specification of the desired end state after this plan is complete, and how to verify it]

### Key Discoveries:
- [Important finding with file:line reference]
- [Pattern to follow]
- [Constraint to work within]

## What We're NOT Doing

[Explicitly list out-of-scope items to prevent scope creep]

## Implementation Approach

[High-level strategy and reasoning]

## Phase 1: [Descriptive Name]

### Overview
[What this phase accomplishes]

**TDD Approach**: This phase follows Test-Driven Development:
1. Write tests first (RED phase)
2. Implement to make tests pass (GREEN phase)
3. Refactor while keeping tests green
4. Validate by making a commit (without `--no-verify`, so commit hooks run) and fix any issues that occur

### Step 1: Write Tests First (RED)

#### Test Files to Create/Modify:
**File**: `path/to/file.test.ext`
**Changes**: [Tests to write before implementation]

```
// Test cases that define expected behavior
```

**Expected**: Tests should FAIL (implementation doesn't exist yet)

### Step 2: Implement (GREEN)

#### Implementation Changes:

##### 1. [Component/File Group]
**File**: `path/to/file.ext`
**Changes**: [Summary of changes]

```
// Specific code to add/modify
```

**Expected**: Tests should PASS after this implementation

### Step 3: Refactor (if needed)

[Improvements to make while keeping tests green]

### Success Criteria:

#### Automated Verification (TDD Cycle):
- [ ] **RED**: Initial tests fail (verified types/implementation missing)
- [ ] **GREEN**: Tests pass after implementation
- [ ] **VALIDATE**: Run project validation commands (see AGENTS.md) — lint, fmt, check, tests all pass
- [ ] No regressions in existing tests

#### Manual Verification:
- [ ] Feature works as expected when tested via UI
- [ ] Performance is acceptable under load
- [ ] Edge case handling verified manually
- [ ] No regressions in related features

**Implementation Note**: After completing this phase and all automated verification passes (including being able to commit without `--no-verify`), pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 2: [Descriptive Name]

[Similar structure with both automated and manual success criteria...]

---

## Testing Strategy

### Unit Tests:
- [What to test]
- [Key edge cases]

### Integration Tests:
- [End-to-end scenarios]

### Manual Testing Steps:
1. [Specific step to verify feature]
2. [Another verification step]
3. [Edge case to test manually]

## Performance Considerations

[Any performance implications or optimizations needed]

## Migration Notes

[If applicable, how to handle existing data/systems]

## References

- Original task: `thoughts/tasks/task-name/task.md`
- Related research: `thoughts/research/[relevant].md`
- Similar implementation: `[file:line]`
````

### Step 5: Sync and Review

1. **Present the draft plan location**:
   ```
   I've created the initial implementation plan at:
   `thoughts/tasks/task-name/plan.md`

   Please review it and let me know:
   - Are the phases properly scoped?
   - Are the success criteria specific enough?
   - Any technical details that need adjustment?
   - Missing edge cases or considerations?
   ```

2. **Iterate based on feedback** - be ready to:
   - Add missing phases
   - Adjust technical approach
   - Clarify success criteria (both automated and manual)
   - Add/remove scope items

4. **Continue refining** until the user is satisfied

## Important Guidelines

1. **Be Skeptical**:
   - Question vague requirements
   - Identify potential issues early
   - Ask "why" and "what about"
   - Don't assume - verify with code

2. **Be Interactive**:
   - Don't write the full plan in one shot
   - Get buy-in at each major step
   - Allow course corrections
   - Work collaboratively

3. **Be Thorough**:
   - Read all context files COMPLETELY before planning
   - Research actual code patterns using parallel sub-tasks
   - Include specific file paths and line numbers
   - Write measurable success criteria with clear automated vs manual distinction
   - Automated steps should use project task commands whenever possible (see AGENTS.md)
   - While working on issues that commit hooks flagged, fix and test fixes in this order:
     1. Run project linter when you've corrected linting issues
     2. Run project formatter when you've fixed formatting
     3. Run project type checker after you've fixed type warnings or errors
     4. Run project tests as a last step

4. **Be Practical**:
   - Focus on incremental, testable changes
   - Consider migration and rollback
   - Think about edge cases
   - Include "what we're NOT doing"

5. **Track Progress**:
   - Use todo list to track planning tasks
   - Update todos as you complete research
   - Mark planning tasks complete when done

6. **No Open Questions in Final Plan**:
   - If you encounter open questions during planning, STOP
   - Research or ask for clarification immediately
   - Do NOT write the plan with unresolved questions
   - The implementation plan must be complete and actionable
   - Every decision must be made before finalizing the plan

## Success Criteria Guidelines

**Always separate success criteria into two categories:**

1. **Automated Verification** (can be run by execution agents):
   - Commands that can be run: run project linter, run project formatter, run project type checker, run project tests, etc. (see AGENTS.md)
   - Specific files that should exist
   - Code compilation/type checking
   - Automated test suites

2. **Manual Verification** (requires human testing):
   - UI/UX functionality
   - Performance under real conditions
   - Edge cases that are hard to automate
   - User acceptance criteria

**Format example:**
```markdown
### Success Criteria:

#### Automated Verification:
- [ ] All unit tests pass: Run project tests (see AGENTS.md)
- [ ] No linting errors: Run project linter
- [ ] No formatting errors: Run project formatter
- [ ] No type errors: Run project type checker
- [ ] Dev server starts successfully
- [ ] API endpoint returns 200: `curl localhost:<port>/api/new-endpoint`

#### Manual Verification:
- [ ] New feature appears correctly in the UI
- [ ] Performance is acceptable with 1000+ items
- [ ] Error messages are user-friendly
- [ ] Feature works correctly on mobile devices
```

## Common Patterns

### For Database Changes:
- Start with schema/migration
- Add store methods
- Update business logic
- Expose via API
- Update clients

### For New Features:
- Research existing patterns first
- Start with data model
- Build backend logic
- Add API endpoints
- Implement UI last

### For Refactoring:
- Document current behavior
- Plan incremental changes
- Maintain backwards compatibility
- Include migration strategy

## Sub-task Spawning Best Practices

When spawning research sub-tasks:

1. **Spawn multiple tasks in parallel** for efficiency
2. **Each task should be focused** on a specific area
3. **Provide detailed instructions** including:
   - Exactly what to search for
   - Which directories to focus on
   - What information to extract
   - Expected output format
4. **Be EXTREMELY specific about directories**:
   - Include the full path context in your prompts
5. **Specify read-only tools** to use
6. **Request specific file:line references** in responses
7. **Wait for all tasks to complete** before synthesizing
8. **Verify sub-task results**:
   - If a sub-task returns unexpected results, spawn follow-up tasks
   - Cross-check findings against the actual codebase
   - Don't accept results that seem incorrect

Example of spawning multiple tasks:
```python
# Spawn these tasks concurrently:
tasks = [
    @codebase-locator("Research database schema", db_research_prompt),
    @codebase-analyzer("Find API patterns", api_research_prompt),
    @codebase-pattern-finder("Investigate UI components", ui_research_prompt),
    @codebase-pattern-finder("Check test patterns", test_research_prompt)
]
```

## Example Interaction Flow

```
User: /create-plan
Assistant: I'll help you create a detailed implementation plan...

User: We need to add parent-child tracking for sub-tasks. See thoughts/tasks/parent-child-tracking/task.md
Assistant: Let me read that task file completely first...

[Reads file fully]

Based on the ticket, I understand we need to track parent-child relationships. Before I start planning, I have some questions...

[Interactive process continues...]
```
