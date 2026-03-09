#!/usr/bin/env python3
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import json, uuid, random, string, os, re

def nano_id():
    return ''.join(random.choices(string.ascii_letters + string.digits, k=21))

def gauge(title, promql, max_val, unit='UNIT_NUMBER', arc=True, threshold_by='THRESHOLD_BY_UNSPECIFIED', display_name=True):
    """
    arc=False  → number-card style (no inner/outer arc), thresholdBy=THRESHOLD_BY_VALUE
    arc=True   → standard arc gauge
    """
    return {
        'id': {'value': str(uuid.uuid4())},
        'title': title,
        'definition': {
            'gauge': {
                'query': {
                    'metrics': {
                        'promqlQuery': {'value': promql},
                        'aggregation': 'AGGREGATION_LAST',
                        'filters': [],
                        'editorMode': 'METRICS_QUERY_EDITOR_MODE_BUILDER',
                        'promqlQueryType': 'PROM_QL_QUERY_TYPE_RANGE'
                    }
                },
                'min': 0,
                'max': max_val,
                'showInnerArc': arc,
                'showOuterArc': arc,
                'unit': unit,
                'thresholds': [
                    {'from': 0,  'color': 'var(--c-severity-log-verbose)'},
                    {'from': 33, 'color': 'var(--c-severity-log-warning)'},
                    {'from': 66, 'color': 'var(--c-severity-log-error)'},
                ],
                'dataModeType': 'DATA_MODE_TYPE_HIGH_UNSPECIFIED',
                'thresholdBy': 'THRESHOLD_BY_VALUE' if not arc else threshold_by,
                'decimal': 2,
                'thresholdType': 'THRESHOLD_TYPE_RELATIVE',
                'legend': {
                    'isVisible': True,
                    'columns': [],
                    'groupByQuery': True,
                    'placement': 'LEGEND_PLACEMENT_AUTO'
                },
                'legendBy': 'LEGEND_BY_GROUPS',
                'displaySeriesName': display_name,
                'decimalPrecision': False
            }
        }
    }

def line(title, promql, name, color='classic', template=None):
    qd = {
        'id': str(uuid.uuid4()),
        'query': {
            'metrics': {
                'promqlQuery': {'value': promql},
                'filters': [],
                'editorMode': 'METRICS_QUERY_EDITOR_MODE_BUILDER',
                'seriesLimitType': 'METRICS_SERIES_LIMIT_TYPE_BY_SERIES_COUNT'
            }
        },
        'seriesCountLimit': '20',
        'unit': 'UNIT_UNSPECIFIED',
        'scaleType': 'SCALE_TYPE_LINEAR',
        'name': name,
        'isVisible': True,
        'colorScheme': color,
        'resolution': {'bucketsPresented': 96},
        'dataModeType': 'DATA_MODE_TYPE_HIGH_UNSPECIFIED',
        'decimal': 2,
        'hashColors': False,
        'decimalPrecision': False,
        'intervalResolution': {'auto': {'minimumInterval': '15s', 'maximumDataPoints': 200}}
    }
    if template:
        qd['seriesNameTemplate'] = template
    return {
        'id': {'value': str(uuid.uuid4())},
        'title': title,
        'definition': {
            'lineChart': {
                'legend': {'isVisible': True, 'columns': [], 'groupByQuery': True, 'placement': 'LEGEND_PLACEMENT_AUTO'},
                'tooltip': {'showLabels': False, 'type': 'TOOLTIP_TYPE_ALL'},
                'queryDefinitions': [qd],
                'stackedLine': 'STACKED_LINE_UNSPECIFIED',
                'connectNulls': False
            }
        }
    }

def datatable(title, dpquery, columns):
    return {
        'id': {'value': str(uuid.uuid4())},
        'title': title,
        'definition': {
            'dataTable': {
                'query': {
                    'dataprime': {
                        'dataprimeQuery': {'text': dpquery},
                        'filters': []
                    }
                },
                'resultsPerPage': 50,
                'rowStyle': 'ROW_STYLE_ONE_LINE',
                'columns': columns,
                'dataModeType': 'DATA_MODE_TYPE_HIGH_UNSPECIFIED'
            }
        }
    }

def row(height, widgets):
    return {
        'id': {'value': str(uuid.uuid4())},
        'appearance': {'height': height},
        'widgets': widgets
    }

def section(rows):
    return {
        'id': {'value': str(uuid.uuid4())},
        'rows': rows,
        'options': {'internal': {}}
    }

d = {
    'id': nano_id(),
    'name': 'Claude Code Monitoring',
    'layout': {
        'sections': [

            # ── Section 1: KPI Overview (number cards + arc gauges) ───────────
            section([
                row(19, [
                    # arc=False → number-card style (matches Coralogix export)
                    gauge('Total Sessions',   'sum(claude_code_session_count_1_total{})',      50,      arc=False, display_name=False),
                    gauge('Total Cost (USD)',  'sum(claude_code_cost_usage_USD_total{})',       10,      arc=False, display_name=False),
                    gauge('Total Tokens',      'sum(claude_code_token_usage_1_total{})',        500000,  arc=True),
                    gauge('Active Time (sec)', 'sum(claude_code_active_time_total_s_total{})', 3600,    arc=True),
                ]),
            ]),

            # ── Section 2: All charts + tables ───────────────────────────────
            section([

                # ── Section: Engineering — Code Changes ───────────────────────
                # Lines added AND removed in a single chart via change_type label
                row(36, [
                    line(
                        'Lines of Code Added & Removed',
                        'sum by (change_type) (claude_code_lines_of_code_count_1_total{})',
                        'Lines by Type', 'classic', '{{change_type}}'
                    ),
                    line(
                        'Commits Over Time',
                        'sum(claude_code_commit_count_total{})',
                        'Commits', 'warm'
                    ),
                ]),

                # ── Section: Engineering — Cost & Sessions ────────────────────
                row(36, [
                    line(
                        'Cost per Model (USD)',
                        'sum by (model) (claude_code_cost_usage_USD_total{})',
                        'Cost by Model', 'classic', '{{model}}'
                    ),
                    line(
                        'Sessions Over Time',
                        'sum(claude_code_session_count_1_total{})',
                        'Sessions', 'classic'
                    ),
                ]),

                # ── Section: Tool Activity ────────────────────────────────────
                # claude_code_code_edit_tool_decision_total tracks every time
                # Claude decides to use (or not) the code-edit tool — labelled by decision type
                row(36, [
                    line(
                        'Code Edit Tool Decisions by Type',
                        'sum by (decision) (claude_code_code_edit_tool_decision_total{})',
                        'Decision Type', 'classic', '{{decision}}'
                    ),
                    line(
                        'Code Edit Tool Decisions Over Time',
                        'sum(claude_code_code_edit_tool_decision_total{})',
                        'Total Decisions', 'teal'
                    ),
                ]),
                # Edit tool decision rate gauge (accepted vs total)
                row(19, [
                    gauge(
                        'Edit Tool Acceptance Rate (%)',
                        '100 * sum(claude_code_code_edit_tool_decision_total{decision="accept"}) / clamp_min(sum(claude_code_code_edit_tool_decision_total{}), 1)',
                        100
                    ),
                    line(
                        'Token Usage by Type',
                        'sum by (type) (claude_code_token_usage_1_total{})',
                        'Tokens by Type', 'cold', '{{type}}'
                    ),
                ]),

                # ── Section: User Activity ────────────────────────────────────
                row(36, [
                    line(
                        'Cost per Session (USD)',
                        'sum(claude_code_cost_usage_USD_total{}) / clamp_min(sum(claude_code_session_count_1_total{}), 1)',
                        'Cost/Session', 'warm'
                    ),
                    line(
                        'Tokens per Session',
                        'sum(claude_code_token_usage_1_total{}) / clamp_min(sum(claude_code_session_count_1_total{}), 1)',
                        'Tokens/Session', 'cold'
                    ),
                ]),
                row(36, [
                    line(
                        'Avg Session Duration (sec)',
                        'sum(claude_code_active_time_total_s_total{}) / clamp_min(sum(claude_code_session_count_1_total{}), 1)',
                        'Avg Duration', 'classic'
                    ),
                    line(
                        'Token Usage by Model',
                        'sum by (model) (claude_code_token_usage_1_total{})',
                        'Tokens by Model', 'cold', '{{model}}'
                    ),
                ]),

                # ── Prompt Log Table ─────────────────────────────────────────
                row(55, [
                    datatable(
                        'Prompt Log',
                        (
                            "source logs\n"
                            "| choose $d.logRecord.attributes['user.id'] as user_id,"
                            " $d.logRecord.attributes['session.id'] as sessions,"
                            " $d.logRecord.attributes.prompt as prompt,"
                            " $d ~~ 'model' as model"
                        ),
                        [
                            {'field': 'user_id',  'width': 200},
                            {'field': 'sessions', 'width': 240},
                            {'field': 'model',    'width': 200},
                            {'field': 'prompt',   'width': 600},
                        ]
                    )
                ]),

            ]),  # end section 2

        ]  # end sections
    },
    'variables': [],
    'variablesV2': [],
    'filters': [],
    'relativeTimeFrame': '3600s',
    'annotations': [],
    'off': {},
    'actions': []
}

existing = [f for f in os.listdir('.') if re.match(r'coralogix-dashboard-v(\d+)\.json', f)]
versions = [int(re.search(r'v(\d+)', f).group(1)) for f in existing]
next_version = max(versions, default=0) + 1
filename = f'coralogix-dashboard-v{next_version}.json'

with open(filename, 'w') as f:
    json.dump(d, f, indent=2)
print(f'{filename} generated')
