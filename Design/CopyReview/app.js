const reviewItems = [
  {
    id: "vault-level-label",
    area: "新建保险箱",
    context: "访问级别字段名称",
    source: "GroupFormSheets.swift",
    old: "访问控制级别",
    proposed: "保险级别",
    rationale: "名称更短，并把用户注意力放在保险箱的整体行为，而不是抽象的权限术语。"
  },
  {
    id: "standard-level-description",
    area: "新建保险箱",
    context: "标准加密说明",
    source: "Models.swift",
    old: "打开即可访问，不需要解锁",
    proposed: "打开即可访问；视频可使用 IINA 播放",
    rationale: "明确标准保险箱的核心体验与外部播放器能力，不增加不必要的安全承诺。"
  },
  {
    id: "extended-level-description",
    area: "新建保险箱",
    context: "扩展加密说明",
    source: "Models.swift",
    old: "需解锁；切到其他保险箱仍保持解锁，也可手动上锁",
    proposed: "需解锁；仅使用内置播放器，切换保险箱后仍保持解锁，也可手动上锁",
    rationale: "保留原有会话行为，同时提前说明受保护视频不再交给 IINA。"
  },
  {
    id: "maximum-level-description",
    area: "新建保险箱",
    context: "最高加密说明",
    source: "Models.swift",
    old: "需解锁；切走或 App 失焦会自动上锁",
    proposed: "需解锁；仅使用内置播放器，切换保险箱或 App 失焦会自动上锁",
    rationale: "把自动上锁触发条件与播放器限制一次讲清，避免用户导入后才发现格式限制。"
  },
  {
    id: "locked-vault-heading",
    area: "保险箱内容页",
    context: "保险箱锁定标题",
    source: "VideoListViews.swift",
    old: "已加密",
    proposed: "保险箱已锁定",
    rationale: "“已加密”描述的是存储状态，而当前界面需要表达的是访问状态。"
  },
  {
    id: "unlock-vault-button",
    area: "保险箱内容页",
    context: "解锁按钮",
    source: "VideoListViews.swift",
    old: "解锁视频 / 解锁图片",
    proposed: "解锁保险箱",
    rationale: "v2 解锁的是保险箱会话和密钥，不只是某一种媒体。"
  },
  {
    id: "protected-format-title",
    area: "受保护视频播放",
    context: "内置播放器不支持当前格式",
    source: "新增界面",
    old: "—（当前没有专用提示）",
    proposed: "此视频格式无法在受保护保险箱中播放",
    rationale: "扩展与最高保险箱禁止产生外部播放器可读的临时明文，因此需要明确解释播放失败。"
  },
  {
    id: "protected-format-message",
    area: "受保护视频播放",
    context: "格式限制说明",
    source: "新增界面",
    old: "—（当前没有专用提示）",
    proposed: "文件仍会安全保存在 Crypta 中。若要播放，请将视频转换为内置播放器支持的格式后重新导入。",
    rationale: "强调数据没有损坏或丢失，同时提供可执行的解决办法。"
  },
  {
    id: "recovery-intro-title",
    area: "首次启用 v2",
    context: "恢复密钥引导标题",
    source: "新增界面",
    old: "—（当前没有恢复密钥）",
    proposed: "保存你的恢复密钥",
    rationale: "直截了当说明当前必须完成的动作。"
  },
  {
    id: "recovery-intro-message",
    area: "首次启用 v2",
    context: "恢复密钥用途说明",
    source: "新增界面",
    old: "—（当前没有恢复密钥）",
    proposed: "如果钥匙串或这台 Mac 无法使用，恢复密钥是重新访问保险箱的唯一方式。Crypta 不会保存可替你恢复的数据副本。",
    rationale: "准确划定恢复边界，不暗示存在服务器备份或后台通道。"
  },
  {
    id: "recovery-copy-button",
    area: "首次启用 v2",
    context: "复制恢复密钥按钮",
    source: "新增界面",
    old: "—",
    proposed: "复制恢复密钥",
    rationale: "动作与对象明确，避免只写“复制”。"
  },
  {
    id: "recovery-save-button",
    area: "首次启用 v2",
    context: "保存恢复密钥按钮",
    source: "新增界面",
    old: "—",
    proposed: "存储到文件",
    rationale: "明确这是导出到本地文件，而不是上传或同步。"
  },
  {
    id: "recovery-confirm-label",
    area: "首次启用 v2",
    context: "恢复密钥确认",
    source: "新增界面",
    old: "—",
    proposed: "我已将恢复密钥保存在安全的位置",
    rationale: "要求用户明确确认，防止跳过关键恢复步骤。"
  },
  {
    id: "migration-title",
    area: "一次性迁移",
    context: "迁移引导标题",
    source: "新增界面",
    old: "—（当前没有迁移界面）",
    proposed: "升级 Crypta 保险库",
    rationale: "使用面向用户的结果描述，不暴露格式版本或内部实现。"
  },
  {
    id: "migration-message",
    area: "一次性迁移",
    context: "迁移安全说明",
    source: "新增界面",
    old: "—（当前没有迁移界面）",
    proposed: "Crypta 将在本机重新加密现有文件。每个文件只有在新副本通过完整性验证后，才会删除原副本。",
    rationale: "把用户最关心的本地处理、验证顺序和原文件删除条件说清楚。"
  },
  {
    id: "migration-start-button",
    area: "一次性迁移",
    context: "开始迁移按钮",
    source: "新增界面",
    old: "—",
    proposed: "开始安全升级",
    rationale: "与普通导入区分开，并强调这是受保护的升级流程。"
  },
  {
    id: "migration-progress",
    area: "一次性迁移",
    context: "匿名迁移进度",
    source: "新增界面",
    old: "—",
    proposed: "正在处理第 {current} 项，共 {total} 项",
    rationale: "迁移日志和进度不展示真实文件名，避免标题进入日志、截图或支持材料。"
  },
  {
    id: "migration-complete",
    area: "一次性迁移",
    context: "迁移完成",
    source: "新增界面",
    old: "—",
    proposed: "保险库升级完成",
    rationale: "完成提示保持简洁，详细校验结果可以作为次要信息展示。"
  },
  {
    id: "decrypt-export-message",
    area: "解密导出",
    context: "导出后移除说明",
    source: "ContentView.swift",
    old: "解密后的文件会从 Crypta 加密库中移除。",
    proposed: "文件成功写入并通过验证后，Crypta 才会删除保险库中的副本。",
    rationale: "准确表达原子操作顺序，避免用户误解为先删后写。"
  },
  {
    id: "recovery-access-title",
    area: "设备恢复",
    context: "钥匙串或设备密钥不可用时的标题",
    source: "V2/RecoveryMigrationViews.swift",
    old: "—（当前只会显示通用错误）",
    proposed: "使用恢复密钥",
    rationale: "明确当前任务是恢复访问，不会让用户误以为需要重新创建保险箱。"
  },
  {
    id: "recovery-access-message",
    area: "设备恢复",
    context: "恢复范围与隐私说明",
    source: "V2/RecoveryMigrationViews.swift",
    old: "—（当前只会显示通用错误）",
    proposed: "输入你保存的恢复密钥，以重新连接这台 Mac 并访问保险箱。恢复过程只在本机进行。",
    rationale: "说明恢复会重建设备访问，同时再次确认密钥和目录不会发送到外部。"
  },
  {
    id: "recovery-access-field",
    area: "设备恢复",
    context: "恢复密钥输入框标签",
    source: "V2/RecoveryMigrationViews.swift",
    old: "—",
    proposed: "恢复密钥",
    rationale: "使用与首次保存界面一致的对象名称，不引入额外术语。"
  },
  {
    id: "recovery-access-button",
    area: "设备恢复",
    context: "提交恢复密钥按钮",
    source: "V2/RecoveryMigrationViews.swift",
    old: "—",
    proposed: "恢复访问",
    rationale: "描述结果而不是内部的钥匙串写入或设备密钥重建动作。"
  },
  {
    id: "recovery-access-invalid",
    area: "设备恢复",
    context: "恢复密钥无法匹配任何保险箱",
    source: "V2/RecoveryMigrationViews.swift",
    old: "—",
    proposed: "恢复密钥无效",
    rationale: "不泄露保险箱数量、名称或匹配细节，只给出可安全展示的失败原因。"
  },
  {
    id: "recovery-access-complete",
    area: "设备恢复",
    context: "恢复完成提示",
    source: "V2/RecoveryMigrationViews.swift",
    old: "—",
    proposed: "已恢复对保险箱的访问",
    rationale: "确认访问已经恢复，不暗示媒体被解密、复制或上传。"
  },
  {
    id: "recovery-file-default-name",
    area: "恢复密钥",
    context: "存储到文件时的默认文件名",
    source: "V2/V2CryptaLibrary.swift",
    old: "—（当前不预填文件名）",
    proposed: "Crypta 恢复密钥.txt",
    rationale: "文件离开 App 后仍能辨认用途，同时不包含保险箱名称或其他敏感信息。"
  },
  {
    id: "import-source-cleanup-warning",
    area: "文件导入",
    context: "加密副本已验证，但个别原文件删除失败",
    source: "ContentView.swift",
    old: "—（当前完成提示不区分原文件删除结果）",
    proposed: "有 {count} 个原文件未能删除；加密副本已经完整验证并安全保留。",
    rationale: "准确区分“加密导入成功”和“原文件清理失败”，避免用户误以为原位置已经不再保留明文。"
  },
  {
    id: "migration-failure-message",
    area: "一次性迁移",
    context: "迁移中断或失败后的通用说明",
    source: "V2/RecoveryMigrationViews.swift",
    old: "—（当前只会显示系统错误）",
    proposed: "保险库升级未完成。Crypta 已保留可用数据，你可以稍后重试。",
    rationale: "不展示文件名或内部阶段，并明确失败不会要求用户立刻处理明文副本。"
  }
];

const storageKey = "crypta-copy-review-v1";
const template = document.querySelector("#reviewCardTemplate");
const list = document.querySelector("#reviewList");
const emptyState = document.querySelector("#emptyState");
const searchInput = document.querySelector("#searchInput");
const resetDialog = document.querySelector("#resetDialog");

let activeFilter = "all";
let reviewState = loadState();

function loadState() {
  try {
    const parsed = JSON.parse(localStorage.getItem(storageKey) || "{}");
    return reviewItems.reduce((result, item) => {
      const saved = parsed[item.id];
      result[item.id] = {
        decision: ["approved", "edited", "kept"].includes(saved?.decision) ? saved.decision : "pending",
        value: typeof saved?.value === "string" ? saved.value : item.proposed
      };
      return result;
    }, {});
  } catch {
    return Object.fromEntries(
      reviewItems.map((item) => [item.id, { decision: "pending", value: item.proposed }])
    );
  }
}

function persistState() {
  localStorage.setItem(storageKey, JSON.stringify(reviewState));
}

function statusLabel(status) {
  return {
    pending: "待决定",
    approved: "已批准新版",
    edited: "已编辑并批准",
    kept: "保留原文"
  }[status];
}

function render() {
  list.replaceChildren();
  const query = searchInput.value.trim().toLocaleLowerCase("zh-Hans");
  const visibleItems = reviewItems.filter((item) => {
    const state = reviewState[item.id];
    const matchesFilter = activeFilter === "all" || state.decision === activeFilter;
    const haystack = [item.area, item.context, item.old, item.proposed, state.value, item.rationale]
      .join(" ")
      .toLocaleLowerCase("zh-Hans");
    return matchesFilter && (!query || haystack.includes(query));
  });

  visibleItems.forEach((item) => {
    const state = reviewState[item.id];
    const fragment = template.content.cloneNode(true);
    const card = fragment.querySelector(".review-card");
    card.dataset.id = item.id;
    card.dataset.status = state.decision;
    fragment.querySelector(".card-index").textContent =
      String(reviewItems.indexOf(item) + 1).padStart(2, "0");
    fragment.querySelector(".card-area").textContent = item.area;
    fragment.querySelector(".card-context").textContent = item.context;
    fragment.querySelector(".card-rationale").textContent = item.rationale;
    fragment.querySelector(".source-location").textContent = item.source;
    fragment.querySelector(".old-value").textContent = item.old;
    fragment.querySelector(".status-badge").textContent = statusLabel(state.decision);

    const textarea = fragment.querySelector(".new-value");
    textarea.value = state.value;
    textarea.addEventListener("input", (event) => {
      reviewState[item.id].value = event.target.value;
      if (reviewState[item.id].decision === "approved" && event.target.value !== item.proposed) {
        reviewState[item.id].decision = "edited";
      }
      persistState();
      updateSummary();
      syncCard(card, item);
    });

    fragment.querySelectorAll(".decision-button").forEach((button) => {
      const decision = button.dataset.decision;
      button.classList.toggle("is-selected", decision === state.decision);
      button.addEventListener("click", () => {
        if (decision === "approved") {
          reviewState[item.id].value = item.proposed;
        } else if (decision === "kept") {
          reviewState[item.id].value = item.old;
        } else if (reviewState[item.id].value === item.proposed) {
          textarea.focus();
          textarea.select();
          return;
        }
        reviewState[item.id].decision = decision;
        textarea.value = reviewState[item.id].value;
        persistState();
        render();
      });
    });
    list.append(fragment);
  });

  emptyState.hidden = visibleItems.length !== 0;
  updateSummary();
}

function syncCard(card, item) {
  const state = reviewState[item.id];
  card.dataset.status = state.decision;
  card.querySelector(".status-badge").textContent = statusLabel(state.decision);
  card.querySelectorAll(".decision-button").forEach((button) => {
    button.classList.toggle("is-selected", button.dataset.decision === state.decision);
  });
}

function updateSummary() {
  const counts = { pending: 0, approved: 0, edited: 0, kept: 0 };
  Object.values(reviewState).forEach((state) => counts[state.decision]++);
  const decided = reviewItems.length - counts.pending;
  const percent = Math.round((decided / reviewItems.length) * 100);

  document.querySelector("#totalCount").textContent = reviewItems.length;
  document.querySelector("#approvedCount").textContent = counts.approved;
  document.querySelector("#editedCount").textContent = counts.edited;
  document.querySelector("#keptCount").textContent = counts.kept;
  document.querySelector("#progressValue").textContent = `${percent}%`;
  document.querySelector("#progressRing").style.setProperty("--progress", `${percent * 3.6}deg`);
  document.querySelector("#remainingCount").textContent =
    counts.pending === 0 ? "全部条目均已决定" : `尚有 ${counts.pending} 条待决定`;
}

document.querySelectorAll(".filter-tab").forEach((button) => {
  button.addEventListener("click", () => {
    activeFilter = button.dataset.filter;
    document.querySelectorAll(".filter-tab").forEach((tab) => {
      tab.classList.toggle("is-active", tab === button);
    });
    render();
  });
});

searchInput.addEventListener("input", render);

document.querySelector("#exportButton").addEventListener("click", () => {
  const decisions = reviewItems.map((item) => ({
    id: item.id,
    context: item.context,
    source: item.source,
    original: item.old,
    proposed: item.proposed,
    decision: reviewState[item.id].decision,
    approvedText: reviewState[item.id].decision === "kept" ? item.old : reviewState[item.id].value
  }));
  const payload = {
    schema: "com.crypta.copy-review",
    version: 1,
    exportedAt: new Date().toISOString(),
    complete: decisions.every((item) => item.decision !== "pending"),
    decisions
  };
  const blob = new Blob([`${JSON.stringify(payload, null, 2)}\n`], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = "crypta-copy-review.json";
  link.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 1_000);
});

document.querySelector("#resetButton").addEventListener("click", () => resetDialog.showModal());
document.querySelector("#confirmReset").addEventListener("click", () => {
  localStorage.removeItem(storageKey);
  reviewState = loadState();
  render();
});

render();
