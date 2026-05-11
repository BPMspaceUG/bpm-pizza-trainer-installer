let csrfToken = '';

async function fetchToken() {
  try {
    const response = await fetch('/api/token');
    if (response.ok) {
      const data = await response.json();
      csrfToken = data.token || '';
    }
  } catch (_) { /* ignore, action requests will be rejected if token is missing */ }
}

const platformValue = document.getElementById('platformValue');
const rootValue = document.getElementById('rootValue');
const checkpointValue = document.getElementById('checkpointValue');
const jobValue = document.getElementById('jobValue');
const jobLog = document.getElementById('jobLog');
const jobMeta = document.getElementById('jobMeta');
const rootInput = document.getElementById('rootInput');
const applyRootButton = document.getElementById('applyRoot');
const snapshotSelect = document.getElementById('snapshotSelect');
const refreshButton = document.getElementById('refreshStatus');
const restoreButton = document.getElementById('restoreSnapshot');
const actionButtons = Array.from(document.querySelectorAll('[data-action]'));

async function fetchStatus() {
  const response = await fetch('/api/status');
  if (!response.ok) {
    throw new Error(`status request failed: ${response.status}`);
  }
  return response.json();
}

function renderStatus(status) {
  platformValue.textContent = status.platform;
  rootValue.textContent = status.root;
  if (document.activeElement !== rootInput) {
    rootInput.value = status.root;
  }
  checkpointValue.textContent = status.checkpointPath;
  jobValue.textContent = status.job.running ? `${status.job.name} running` : (status.job.name || 'Idle');
  jobLog.textContent = status.job.log || 'Waiting for action...';
  jobMeta.textContent = formatMeta(status.job);
  renderSnapshots(status.snapshots);
  setBusyState(status.job.running);
}

function renderSnapshots(snapshots) {
  const current = snapshotSelect.value;
  snapshotSelect.innerHTML = '';

  const fallbackOption = document.createElement('option');
  fallbackOption.value = '';
  fallbackOption.textContent = 'Root fallback copy';
  snapshotSelect.appendChild(fallbackOption);

  snapshots.forEach((snapshot) => {
    const option = document.createElement('option');
    option.value = snapshot;
    option.textContent = snapshot;
    snapshotSelect.appendChild(option);
  });

  if ([...snapshotSelect.options].some((option) => option.value === current)) {
    snapshotSelect.value = current;
  }
}

function formatMeta(job) {
  if (!job.name) {
    return 'No action has been run yet.';
  }
  const parts = [`Action: ${job.name}`];
  if (job.startedAt && job.startedAt !== '0001-01-01T00:00:00Z') {
    parts.push(`Started: ${new Date(job.startedAt).toLocaleString()}`);
  }
  if (!job.running && job.endedAt && job.endedAt !== '0001-01-01T00:00:00Z') {
    parts.push(`Finished: ${new Date(job.endedAt).toLocaleString()}`);
    parts.push(`Exit: ${job.exitCode}`);
  }
  if (job.error) {
    parts.push(`Error: ${job.error}`);
  }
  return parts.join(' | ');
}

function setBusyState(isBusy) {
  actionButtons.forEach((button) => {
    button.disabled = isBusy;
  });
  applyRootButton.disabled = isBusy;
  restoreButton.disabled = isBusy;
}

function actionPayload(action) {
  return {
    root: rootInput.value.trim(),
    action,
    snapshot: snapshotSelect.value,
    useFallback: document.getElementById('useFallback').checked,
    skipPreflight: document.getElementById('skipPreflight').checked,
    resume: document.getElementById('resumeTrainer').checked,
    resetCheckpoint: document.getElementById('resetCheckpoint').checked,
    removeModules: document.getElementById('removeModules').checked,
    gitClean: document.getElementById('gitClean').checked,
    reinstall: document.getElementById('reinstallDeps').checked,
    removePythonEnv: document.getElementById('removePythonEnv').checked,
    removeRepos: document.getElementById('removeRepos').checked,
    dryRun: document.getElementById('dryRun').checked,
  };
}

async function runAction(action) {
  const response = await fetch('/api/action', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken },
    body: JSON.stringify(actionPayload(action)),
  });
  const data = await response.json();
  if (!response.ok && response.status !== 202) {
    throw new Error(data.error || data.message || `action failed: ${response.status}`);
  }
  if (!data.accepted) {
    throw new Error(data.message || 'action was not accepted');
  }
}

async function refreshStatus() {
  try {
    const status = await fetchStatus();
    renderStatus(status);
  } catch (error) {
    jobLog.textContent = String(error);
    jobMeta.textContent = 'Unable to refresh status.';
  }
}

actionButtons.forEach((button) => {
  button.addEventListener('click', async () => {
    try {
      await runAction(button.dataset.action);
      await refreshStatus();
    } catch (error) {
      jobLog.textContent = String(error);
      jobMeta.textContent = 'Action failed before start.';
    }
  });
});

restoreButton.addEventListener('click', async () => {
  try {
    await runAction('snapshot-restore');
    await refreshStatus();
  } catch (error) {
    jobLog.textContent = String(error);
    jobMeta.textContent = 'Restore failed before start.';
  }
});

applyRootButton.addEventListener('click', async () => {
  try {
    await runAction('set-root');
    await refreshStatus();
    jobMeta.textContent = 'Workspace root updated.';
  } catch (error) {
    jobLog.textContent = String(error);
    jobMeta.textContent = 'Root update failed.';
  }
});

rootInput.addEventListener('keydown', async (event) => {
  if (event.key !== 'Enter') {
    return;
  }
  event.preventDefault();
  try {
    await runAction('set-root');
    await refreshStatus();
    jobMeta.textContent = 'Workspace root updated.';
  } catch (error) {
    jobLog.textContent = String(error);
    jobMeta.textContent = 'Root update failed.';
  }
});

refreshButton.addEventListener('click', refreshStatus);

fetchToken().then(() => {
  refreshStatus();
  setInterval(refreshStatus, 2500);
});