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

"""
gen_dashboard.py
----------------
Generates a Coralogix dashboard JSON for Codex CLI sessions based entirely
on log events and traces.

All DataPrime patterns confirmed working in Coralogix dashboard context:
  - Column fields must use $d.<fieldname> format
  - choose command fails for nested keypaths — use create + sort instead
  - groupby + aggregate works with create'd fields
  - countby works with bracket notation ($d.logRecord.attributes['dotted.key'])
  - :number cast required for token count fields (stored as strings)
  - Timestamp bucketing: create day_raw from ($m.timestamp / 1d):string
                         create day from day_raw.substr(0, 10)
  - Metrics export not supported by Codex CLI (openai/codex#10277)

Usage:
    python3 gen_dashboard.py
    # Produces coralogix-dashboard-vN.json (auto-versioned)
    # Import via: Dashboards → New Dashboard → menu icon → Import from JSON
"""

import json, uuid, random, string

# ── DataPrime filter fragments ─────────────────────────────────────────────
F_ORIGIN  = "| filter $d.logRecord.attributes.originator == 'codex_cli_rs'"
F_SSE     = "| filter $d.logRecord.attributes['event.name'] == 'codex.sse_event'"
F_DONE    = "| filter $d.logRecord.attributes['event.kind'] == 'response.completed'"
F_API     = "| filter $d.logRecord.attributes['event.name'] == 'codex.api_request'"
F_TOOL_D  = "| filter $d.logRecord.attributes['event.name'] == 'codex.tool_decision'"
F_TOOL_R  = "| filter $d.logRecord.attributes['event.name'] == 'codex.tool_result'"

def nano_id():
    return ''.join(random.choices(string.ascii_letters + string.digits, k=21))

def uid():
    return str(uuid.uuid4())

# ── Widget builders ────────────────────────────────────────────────────────

def datatable(title, query, columns):
    """Data table widget. columns = list of (field, width) tuples or just field strings."""
    cols = []
    for c in columns:
        if isinstance(c, tuple):
            cols.append({'field': f'$d.{c[0]}', 'width': c[1]})
        else:
            cols.append({'field': f'$d.{c}'})
    return {
        'id': {'value': uid()},
        'title': title,
        'definition': {
            'dataTable': {
                'query': {
                    'dataprime': {
                        'dataprimeQuery': {'text': query},
                        'filters': []
                    }
                },
                'resultsPerPage': 100,
                'rowStyle': 'ROW_STYLE_ONE_LINE',
                'columns': cols,
                'dataModeType': 'DATA_MODE_TYPE_HIGH_UNSPECIFIED'
            }
        }
    }

def horizontal_bar(title, query, group_name):
    """Horizontal bar chart widget."""
    return {
        'id': {'value': uid()},
        'title': title,
        'definition': {
            'horizontalBarChart': {
                'query': {
                    'dataprime': {
                        'dataprimeQuery': {'text': query},
                        'filters': [],
                        'groupNames': [group_name]
                    }
                },
                'maxBarsPerChart': 24,
                'stackDefinition': {'maxSlicesPerBar': 7},
                'scaleType': 'SCALE_TYPE_LINEAR',
                'colorsBy': {'aggregation': {}},
                'unit': 'UNIT_UNSPECIFIED',
                'displayOnBar': True,
                'yAxisViewBy': {'value': {}},
                'sortBy': 'SORT_BY_TYPE_VALUE',
                'colorScheme': 'classic',
                'dataModeType': 'DATA_MODE_TYPE_HIGH_UNSPECIFIED',
                'decimal': 2,
                'legend': {
                    'isVisible': True,
                    'columns': [],
                    'groupByQuery': True,
                    'placement': 'LEGEND_PLACEMENT_AUTO',
                    'seriesVisibility': {'querySeries': [], 'annotationSeries': []}
                },
                'hashColors': False,
                'decimalPrecision': False
            }
        }
    }

def line_chart(title, query):
    """Line chart widget (time-series)."""
    return {
        'id': {'value': uid()},
        'title': title,
        'definition': {
            'lineChart': {
                'legend': {
                    'isVisible': True,
                    'columns': [],
                    'groupByQuery': True,
                    'placement': 'LEGEND_PLACEMENT_AUTO',
                    'seriesVisibility': {'querySeries': [], 'annotationSeries': []}
                },
                'tooltip': {'showLabels': False, 'type': 'TOOLTIP_TYPE_ALL'},
                'queryDefinitions': [
                    {
                        'id': uid(),
                        'query': {
                            'dataprime': {
                                'dataprimeQuery': {'text': query},
                                'filters': []
                            }
                        },
                        'seriesCountLimit': '20',
                        'unit': 'UNIT_UNSPECIFIED',
                        'scaleType': 'SCALE_TYPE_LINEAR',
                        'name': 'Query 1',
                        'isVisible': True,
                        'colorScheme': 'classic',
                        'dataModeType': 'DATA_MODE_TYPE_HIGH_UNSPECIFIED',
                        'decimal': 2,
                        'hashColors': False,
                        'decimalPrecision': False
                    }
                ],
                'stackedLine': 'STACKED_LINE_UNSPECIFIED',
                'connectNulls': False
            }
        }
    }

def row(height, widgets):
    return {
        'id': {'value': uid()},
        'appearance': {'height': height},
        'widgets': widgets
    }

def section(name, rows):
    return {
        'id': {'value': uid()},
        'rows': rows,
        'options': {
            'custom': {
                'name': name,
                'collapsed': False,
                'color': {'predefined': 'SECTION_PREDEFINED_COLOR_UNSPECIFIED'}
            }
        }
    }

# ── Dashboard definition ───────────────────────────────────────────────────

d = {
    'id': nano_id(),
    'name': 'Codex CLI Sessions',
    'layout': {
        'sections': [

            # ── Section 1: Sessions & User Activity ───────────────────────
            section('Sessions & User Activity', [
                row(19, [
                    datatable(
                        'Sessions by User',
                        (
                            f"source logs\n{F_ORIGIN}\n"
                            "| distinct $d.logRecord.attributes['conversation.id'], $d.logRecord.attributes['user.email']\n"
                            "| countby $d.logRecord.attributes['user.email'] as user into session_count desc"
                        ),
                        ['user', 'session_count']
                    ),
                    datatable(
                        'API Requests per Session',
                        (
                            f"source logs\n{F_ORIGIN}\n{F_API}\n"
                            "| create conversation_id from $d.logRecord.attributes['conversation.id']\n"
                            "| create user from $d.logRecord.attributes['user.email']\n"
                            "| groupby conversation_id, user aggregate count() as turns\n"
                            "| sort by turns desc"
                        ),
                        [('conversation_id', 294), ('user', 200), ('turns', 200)]
                    ),
                    line_chart(
                        'Active Users over Time',
                        (
                            f"source logs\n{F_ORIGIN}\n"
                            "| create user from $d.logRecord.attributes['user.email']\n"
                            "| distinct $m.timestamp / 1h as hour, user\n"
                            "| countby hour into active_users asc"
                        )
                    ),
                ]),
            ]),

            # ── Section 2: Tokens ──────────────────────────────────────────
            section('Tokens', [
                row(19, [
                    datatable(
                        'Total Tokens per Session',
                        (
                            f"source logs\n{F_ORIGIN}\n{F_SSE}\n{F_DONE}\n"
                            "| create conversation_id from $d.logRecord.attributes['conversation.id']\n"
                            "| create user from $d.logRecord.attributes['user.email']\n"
                            "| create input from $d.logRecord.attributes.input_token_count:number\n"
                            "| create output from $d.logRecord.attributes.output_token_count:number\n"
                            "| create cached from $d.logRecord.attributes.cached_token_count:number\n"
                            "| groupby conversation_id, user aggregate sum(input) as total_input, sum(output) as total_output, sum(cached) as total_cached\n"
                            "| sort by total_input desc"
                        ),
                        [('conversation_id', 307), ('user', 200), ('total_input', 200), ('total_output', 200), ('total_cached', 200)]
                    ),
                ]),
                row(19, [
                    datatable(
                        'Token Breakdown by Model',
                        (
                            f"source logs\n{F_ORIGIN}\n{F_SSE}\n{F_DONE}\n"
                            "| create model from $d.logRecord.attributes.model\n"
                            "| create input from $d.logRecord.attributes.input_token_count:number\n"
                            "| create output from $d.logRecord.attributes.output_token_count:number\n"
                            "| create cached from $d.logRecord.attributes.cached_token_count:number\n"
                            "| groupby model aggregate sum(input) as total_input, sum(output) as total_output, sum(cached) as total_cached\n"
                            "| sort by total_input desc"
                        ),
                        ['model', 'total_input', 'total_output', 'total_cached']
                    ),
                    horizontal_bar(
                        'Daily Token Usage',
                        (
                            f"source logs\n{F_ORIGIN}\n{F_SSE}\n{F_DONE}\n"
                            "| create input from $d.logRecord.attributes.input_token_count:number\n"
                            "| create output from $d.logRecord.attributes.output_token_count:number\n"
                            "| create day_raw from ($m.timestamp / 1d):string\n"
                            "| create day from day_raw.substr(0, 10)\n"
                            "| groupby day aggregate sum(input) as daily_input, sum(output) as daily_output"
                        ),
                        'day'
                    ),
                ]),
            ]),

            # ── Section 3: Traces ──────────────────────────────────────────
            section('Traces', [
                row(19, [
                    datatable(
                        'Slowest Spans (ms)',
                        (
                            "source spans\n"
                            "| filter $d.serviceName == 'codex_cli_rs'\n"
                            "| create operation from $d.operationName\n"
                            "| create duration_ms from $d.duration:number / 1000000\n"
                            "| sort by duration_ms desc"
                        ),
                        [('operation', 200), ('duration_ms', 595)]
                    ),
                    horizontal_bar(
                        'Span Count by Operation',
                        (
                            "source spans\n"
                            "| filter $d.serviceName == 'codex_cli_rs'\n"
                            "| countby $d.operationName as operation into span_count desc"
                        ),
                        'operation'
                    ),
                ]),
                row(19, [
                    horizontal_bar(
                        'Avg + Max Duration per Operation (ms)',
                        (
                            "source spans\n"
                            "| filter $d.serviceName == 'codex_cli_rs'\n"
                            "| create operation from $d.operationName\n"
                            "| create dur from $d.duration:number / 1000000\n"
                            "| groupby operation aggregate avg(dur) as avg_ms, max(dur) as max_ms\n"
                            "| sort by avg_ms desc"
                        ),
                        'operation'
                    ),
                ]),
            ]),
        ]
    },
    'variables': [],
    'variablesV2': [],
    'filters': [],
    'relativeTimeFrame': '43200s',
    'annotations': [],
    'off': {},
    'actions': []
}

filename = 'coralogix-codex-dashboard.json'

with open(filename, 'w') as f:
    json.dump(d, f, indent=2)
print(f'Generated: {filename}')
print('Import via: Dashboards → New Dashboard → menu icon → Import from JSON')
