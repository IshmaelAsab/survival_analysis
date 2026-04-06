const csvPaths = {
  summary: 'outputs/tables/analysis_session_summary.csv',
  prep: 'outputs/tables/data_preparation_summary.csv',
  horizons: 'outputs/tables/km_horizon_summary.csv',
  models: 'outputs/tables/parametric_model_fit_summary.csv',
  risk: 'outputs/tables/top_cox_risk_factors.csv',
  protective: 'outputs/tables/top_cox_protective_factors.csv',
  aftAccelerators: 'outputs/tables/top_aft_churn_accelerators.csv',
  aftDrivers: 'outputs/tables/top_aft_retention_drivers.csv'
};

const fmtNumber = (value, digits = 2) => {
  const num = Number(value);
  if (Number.isNaN(num)) return value;
  return num.toLocaleString(undefined, { maximumFractionDigits: digits, minimumFractionDigits: digits });
};

const fmtCompact = (value, digits = 0) => {
  const num = Number(value);
  if (Number.isNaN(num)) return value;
  return num.toLocaleString(undefined, { notation: 'compact', maximumFractionDigits: digits });
};

async function fetchCSV(path) {
  const res = await fetch(path);
  if (!res.ok) throw new Error(`Failed to load ${path}`);
  const text = await res.text();
  return parseCSV(text);
}

function parseCSV(text) {
  const rows = [];
  let row = [];
  let value = '';
  let inQuotes = false;

  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    const next = text[i + 1];

    if (char === '"') {
      if (inQuotes && next === '"') {
        value += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (char === ',' && !inQuotes) {
      row.push(value);
      value = '';
    } else if ((char === '\n' || char === '\r') && !inQuotes) {
      if (char === '\r' && next === '\n') i += 1;
      if (value.length > 0 || row.length > 0) {
        row.push(value);
        rows.push(row);
        row = [];
        value = '';
      }
    } else {
      value += char;
    }
  }

  if (value.length > 0 || row.length > 0) {
    row.push(value);
    rows.push(row);
  }

  const [headers, ...dataRows] = rows;
  return dataRows.map((cols) => Object.fromEntries(headers.map((h, idx) => [h, cols[idx] ?? ''])));
}

function setText(id, text) {
  const node = document.getElementById(id);
  if (node) node.textContent = text;
}

function renderKpis(summaryRows, prepRows) {
  const summary = Object.fromEntries(summaryRows.map((row) => [row.item, row.value]));
  const prep = Object.fromEntries(prepRows.map((row) => [row.metric, row.value]));
  setText('hero-peak-month', `Month ${summary['Peak hazard month']}`);
  setText('hero-cox-cindex', fmtNumber(summary['Cox C-index'], 3));
  setText('hero-best-model', summary['Best parametric model']);

  const kpis = [
    { label: 'Customers analyzed', value: fmtCompact(prep['Rows retained']), note: `${fmtCompact(prep['Event count (churn = 1)'])} churn events` },
    { label: 'Censoring rate', value: `${fmtNumber(Number(prep['Censoring rate']) * 100, 1)}%`, note: `${fmtCompact(prep['Censored count (churn = 0)'])} retained observations` },
    { label: 'Peak hazard', value: fmtNumber(summary['Peak hazard value'], 3), note: `Month ${summary['Peak hazard month']}` },
    { label: 'Best parametric AIC', value: fmtNumber(summary['Best parametric AIC'], 1), note: summary['Best parametric model'] }
  ];

  document.getElementById('kpi-grid').innerHTML = kpis.map((item) => `
    <article class="kpi">
      <span>${item.label}</span>
      <strong>${item.value}</strong>
      <p class="factor-meta">${item.note}</p>
    </article>
  `).join('');
}

function renderHorizons(rows) {
  const container = document.getElementById('horizon-grid');
  container.innerHTML = rows.map((row) => `
    <div class="horizon-item">
      <span>Month ${row.month}</span>
      <strong>${fmtNumber(Number(row.survival_probability) * 100, 1)}%</strong>
      <div class="factor-meta">Churn probability ${fmtNumber(Number(row.churn_probability) * 100, 1)}%</div>
    </div>
  `).join('');

  drawLineChart(rows);
}

function drawLineChart(rows) {
  const svg = document.getElementById('survival-chart');
  const width = 640;
  const height = 320;
  const margin = { top: 24, right: 20, bottom: 38, left: 48 };
  const innerW = width - margin.left - margin.right;
  const innerH = height - margin.top - margin.bottom;

  const points = rows.map((row) => ({ x: Number(row.month), y: Number(row.survival_probability) }));
  const xMin = Math.min(...points.map((p) => p.x));
  const xMax = Math.max(...points.map((p) => p.x));
  const yMin = Math.min(...points.map((p) => p.y)) - 0.02;
  const yMax = 1;
  const sx = (x) => margin.left + ((x - xMin) / (xMax - xMin)) * innerW;
  const sy = (y) => margin.top + (1 - (y - yMin) / (yMax - yMin)) * innerH;
  const line = points.map((p) => `${sx(p.x)},${sy(p.y)}`).join(' ');

  const yTicks = [0.75, 0.8, 0.85, 0.9, 0.95, 1.0];
  const xTicks = points.map((p) => p.x);

  svg.innerHTML = `
    <rect x="0" y="0" width="640" height="320" rx="18" fill="transparent"></rect>
    ${yTicks.map((tick) => `
      <g>
        <line x1="${margin.left}" y1="${sy(tick)}" x2="${width - margin.right}" y2="${sy(tick)}" stroke="rgba(158,178,203,0.16)" stroke-dasharray="4 4"></line>
        <text x="12" y="${sy(tick) + 4}" fill="#9eb2cb" font-size="12">${Math.round(tick * 100)}%</text>
      </g>`).join('')}
    ${xTicks.map((tick) => `
      <g>
        <line x1="${sx(tick)}" y1="${margin.top}" x2="${sx(tick)}" y2="${height - margin.bottom}" stroke="rgba(158,178,203,0.08)"></line>
        <text x="${sx(tick)}" y="${height - 10}" text-anchor="middle" fill="#9eb2cb" font-size="12">${tick}m</text>
      </g>`).join('')}
    <polyline fill="none" stroke="#77e0ff" stroke-width="4" points="${line}" stroke-linecap="round" stroke-linejoin="round"></polyline>
    ${points.map((p) => `
      <g>
        <circle cx="${sx(p.x)}" cy="${sy(p.y)}" r="5" fill="#06131f" stroke="#77e0ff" stroke-width="3"></circle>
        <text x="${sx(p.x)}" y="${sy(p.y) - 12}" text-anchor="middle" fill="#edf4ff" font-size="11">${fmtNumber(p.y * 100, 1)}%</text>
      </g>`).join('')}
    <text x="${width / 2}" y="${height - 2}" text-anchor="middle" fill="#9eb2cb" font-size="12">Tenure month</text>
    <text x="18" y="18" fill="#9eb2cb" font-size="12">Survival probability</text>
  `;
}

function renderFactors(containerId, rows, metricKey, opts = {}) {
  const max = opts.max ?? Math.max(...rows.map((row) => Number(row[metricKey])));
  const min = opts.min ?? Math.min(...rows.map((row) => Number(row[metricKey])));
  const inverse = opts.inverse ?? false;
  const unit = opts.unit ?? '';

  document.getElementById(containerId).innerHTML = rows.map((row) => {
    const raw = Number(row[metricKey]);
    const ratio = inverse
      ? ((max - raw) / Math.max(max - min, 0.0001)) * 100
      : (raw / Math.max(max, 0.0001)) * 100;

    return `
      <article class="factor-item">
        <div class="factor-header">
          <strong>${row.term_label}</strong>
          <span class="badge">${fmtNumber(raw, 2)}${unit}</span>
        </div>
        <div class="meter"><span style="width:${Math.max(10, Math.min(100, ratio))}%"></span></div>
        <div class="factor-meta">95% CI ${fmtNumber(row.conf_low, 2)} to ${fmtNumber(row.conf_high, 2)} · p ${Number(row.p_value).toExponential(2)}</div>
      </article>
    `;
  }).join('');
}

function renderModelTable(rows) {
  const sorted = [...rows].sort((a, b) => Number(a.aic) - Number(b.aic));
  document.getElementById('model-table').innerHTML = sorted.map((row) => `
    <tr>
      <td><strong>${row.model}</strong></td>
      <td>${row.effect_scale}</td>
      <td>${fmtNumber(row.aic, 1)}</td>
      <td>${fmtNumber(row.bic, 1)}</td>
      <td>${fmtNumber(row.c_index, 3)}</td>
      <td>${fmtNumber(row.c_index_se, 4)}</td>
    </tr>
  `).join('');
}

function renderError(error) {
  const targets = ['kpi-grid', 'horizon-grid', 'risk-factors', 'protective-factors', 'aft-accelerators', 'aft-drivers', 'model-table'];
  targets.forEach((id) => {
    const node = document.getElementById(id);
    if (node) node.innerHTML = `<div class="error">${error.message}</div>`;
  });
}

(async function init() {
  try {
    const [summary, prep, horizons, models, risk, protective, aftAccelerators, aftDrivers] = await Promise.all([
      fetchCSV(csvPaths.summary),
      fetchCSV(csvPaths.prep),
      fetchCSV(csvPaths.horizons),
      fetchCSV(csvPaths.models),
      fetchCSV(csvPaths.risk),
      fetchCSV(csvPaths.protective),
      fetchCSV(csvPaths.aftAccelerators),
      fetchCSV(csvPaths.aftDrivers)
    ]);

    renderKpis(summary, prep);
    renderHorizons(horizons);
    renderFactors('risk-factors', risk, 'hazard_ratio');
    renderFactors('protective-factors', protective, 'hazard_ratio', { inverse: true });
    renderFactors('aft-accelerators', aftAccelerators, 'time_ratio', { inverse: true });
    renderFactors('aft-drivers', aftDrivers, 'time_ratio');
    renderModelTable(models);
  } catch (error) {
    console.error(error);
    renderError(error);
  }
})();
