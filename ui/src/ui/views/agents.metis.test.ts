/* @vitest-environment jsdom */

import { render } from "lit";
import { describe, expect, it, vi } from "vitest";
import {
  createEmptyAgentTeamBindingDraft,
  createEmptyAgentTeamDraft,
  createEmptyAgentTeamModelDraft,
  createEmptyAgentTeamWorkspaceDraft,
} from "../controllers/agent-teams.ts";
import { renderAgents, type AgentsProps } from "./agents.ts";

function createProps(overrides: Partial<AgentsProps> = {}): AgentsProps {
  const noop = vi.fn();
  return {
    basePath: "",
    loading: false,
    error: null,
    agentsList: {
      defaultId: "alpha",
      mainKey: "main",
      scope: "workspace",
      agents: [{ id: "alpha", name: "Alpha" } as never],
    },
    selectedAgentId: "alpha",
    activePanel: "overview",
    config: { form: null, loading: false, saving: false, dirty: false },
    channels: { snapshot: null, loading: false, error: null, lastSuccess: null },
    cron: { status: null, jobs: [], loading: false, error: null },
    agentFiles: {
      list: null,
      loading: false,
      error: null,
      active: null,
      contents: {},
      drafts: {},
      saving: false,
    },
    agentIdentityLoading: false,
    agentIdentityError: null,
    agentIdentityById: {},
    agentSkills: { report: null, loading: false, error: null, agentId: null, filter: "" },
    toolsCatalog: { loading: false, error: null, result: null },
    toolsEffective: { loading: false, error: null, result: null },
    agentTeams: {
      loading: false,
      saving: false,
      error: null,
      success: null,
      list: { count: 1, teams: [{ id: "content", displayName: "Content Team", members: [] }] },
      selectedId: "content",
      detail: { id: "content", displayName: "Content Team", members: [] },
      draft: { ...createEmptyAgentTeamDraft(), id: "content", displayName: "Content Team" },
      binding: createEmptyAgentTeamBindingDraft(),
      bindingPreview: null,
      bindingResult: null,
      modelLoading: false,
      modelError: null,
      modelResult: null,
      modelDraft: createEmptyAgentTeamModelDraft(),
      workspaceLoading: false,
      workspaceSaving: false,
      workspaceError: null,
      workspace: createEmptyAgentTeamWorkspaceDraft(),
      feishuAuthLoading: false,
      feishuAuthError: null,
      feishuAuthResult: null,
      channelsSnapshot: null,
      configForm: null,
    },
    runtimeSessionKey: "main",
    runtimeSessionMatchesSelectedAgent: false,
    modelCatalog: [],
    onRefresh: noop,
    onSelectAgent: noop,
    onSelectPanel: noop,
    onLoadFiles: noop,
    onSelectFile: noop,
    onFileDraftChange: noop,
    onFileReset: noop,
    onFileSave: noop,
    onToolsProfileChange: noop,
    onToolsOverridesChange: noop,
    onConfigReload: noop,
    onConfigSave: noop,
    onModelChange: noop,
    onModelFallbacksChange: noop,
    onChannelsRefresh: noop,
    onCronRefresh: noop,
    onCronRunNow: noop,
    onTeamsRefresh: noop,
    onSelectTeam: noop,
    onNewTeam: noop,
    onTeamDraftChange: noop,
    onCreateTeam: noop,
    onUpdateTeam: noop,
    onDeleteTeam: noop,
    onTeamBindingChange: noop,
    onPreviewTeamBinding: noop,
    onApplyTeamBinding: noop,
    onTeamModelDraftChange: noop,
    onLoadTeamModel: noop,
    onSaveTeamModel: noop,
    onWorkspaceChange: noop,
    onLoadWorkspaceFiles: noop,
    onLoadWorkspaceFile: noop,
    onSaveWorkspaceFile: noop,
    onStartFeishuOAuth: noop,
    onSkillsFilterChange: noop,
    onSkillsRefresh: noop,
    onAgentSkillToggle: noop,
    onAgentSkillsClear: noop,
    onAgentSkillsDisableAll: noop,
    onSetDefault: noop,
    ...overrides,
  };
}

describe("renderAgents AgentTeam navigation", () => {
  it("renders the Agents main tab with Teams sub-tab content", () => {
    const container = document.createElement("div");
    render(renderAgents(createProps({ activePanel: "teams" })), container);

    const text = container.textContent ?? "";
    const tabs = Array.from(container.querySelectorAll<HTMLButtonElement>(".agent-tab")).map(
      (button) => button.textContent ?? "",
    );
    expect(text).toContain("Alpha (default)");
    expect(tabs.some((tab) => tab.includes("Teams"))).toBe(true);
    expect(text).toContain("Agent Teams");
    expect(text).toContain("Team Wizard");
    expect(text).toContain("Cultivation, Memory & Heartbeat");
  });
});
