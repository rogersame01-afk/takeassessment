Go4 Data Analyst Exercise · Data Pack · September 2026 board dashboard
Account names, owners, people and amounts are illustrative. The business lines, metrics and structure are Go4's.

What this is
An extract of Contract Services pipeline and contracts, marketplace activity by metro, and the draft September board dashboard.
The draft goes to the board on Friday. It was assembled by the commercial team, the same people whose results it reports.

Facts you need
Go4 runs two business lines: a per diem marketplace connecting Athletic Trainers (ATs) with organizations, and Contract Services, which sells managed coverage on 12-month contracts.
Contract Services coverage is staffed from the marketplace AT pool in the same metro.
Pipeline is a CRM extract pulled 10/01/2026. Contracts and Marketplace by Metro come from the Go4 platform database.
Contracts run 12 months. A renewal is entered as a new contract row that starts the day after the old one ends, and the old row is marked Renewed.
The 2027 plan assumes Contract Services retention of 70%.
Each point of company fill rate is worth about $32,750 of annual gross profit.
Tucson launched in August 2026 and Boise in September 2026.
Dates are stored as text in YYYY-MM-DD form. Each tab is a flat table with headers in row 2, so it loads into SQL, a notebook or a pivot table as is.

Tabs
Pipeline · every Contract Services deal created since September 2025, open and closed
Contracts · every Contract Services contract active at any point in 2026, with renewal status at 09/30/2026
Marketplace by Metro · shifts posted, shifts filled and working ATs by metro, April to September 2026
Draft Dashboard · the September board dashboard as drafted, with the commercial team's commentary and calculation notes
Definitions · the current written definition and owner of each dashboard metric
