from fpdf import FPDF

class SlidePDF(FPDF):
    def __init__(self):
        super().__init__(orientation='L', unit='mm', format='A4')
        self.set_auto_page_break(auto=False)

    def add_slide(self, bg_color=(26, 26, 46)):
        self.add_page()
        # Background
        self.set_fill_color(*bg_color)
        self.rect(0, 0, 297, 210, 'F')

    def slide_number(self, num):
        self.set_font('Helvetica', '', 10)
        self.set_text_color(150, 150, 150)
        self.set_xy(280, 195)
        self.cell(10, 10, str(num), align='R')

    def title_text(self, text, y=60, size=40):
        self.set_font('Helvetica', 'B', size)
        self.set_text_color(255, 107, 107)
        self.set_xy(20, y)
        self.cell(257, 20, text, align='C')

    def subtitle_text(self, text, y=85, size=18):
        self.set_font('Helvetica', '', size)
        self.set_text_color(200, 200, 200)
        self.set_xy(20, y)
        self.cell(257, 10, text, align='C')

    def heading(self, text, y=20):
        self.set_font('Helvetica', 'B', 28)
        self.set_text_color(255, 107, 107)
        self.set_xy(20, y)
        self.cell(257, 15, text)

    def body_text(self, text, x=20, y=45, size=14):
        self.set_font('Helvetica', '', size)
        self.set_text_color(230, 230, 230)
        self.set_xy(x, y)
        self.multi_cell(257, 8, text)

    def bullet(self, text, x=25, y=None, highlight=None):
        if y:
            self.set_xy(x, y)
        # Bullet point
        self.set_fill_color(255, 107, 107)
        self.ellipse(x, self.get_y() + 3, 4, 4, 'F')
        self.set_xy(x + 8, self.get_y())
        self.set_font('Helvetica', '', 13)
        self.set_text_color(220, 220, 220)

        if highlight:
            parts = text.split(highlight)
            if len(parts) == 2:
                self.cell(self.get_string_width(parts[0]), 8, parts[0])
                self.set_font('Helvetica', 'B', 13)
                self.set_text_color(254, 202, 87)
                self.cell(self.get_string_width(highlight), 8, highlight)
                self.set_font('Helvetica', '', 13)
                self.set_text_color(220, 220, 220)
                self.cell(0, 8, parts[1], ln=True)
            else:
                self.cell(0, 8, text, ln=True)
        else:
            self.cell(0, 8, text, ln=True)
        self.set_y(self.get_y() + 2)

    def box(self, x, y, w, h, title, items):
        # Box background
        self.set_fill_color(40, 40, 60)
        self.set_draw_color(80, 80, 100)
        self.rect(x, y, w, h, 'DF')
        # Title
        self.set_font('Helvetica', 'B', 14)
        self.set_text_color(72, 219, 251)
        self.set_xy(x + 5, y + 5)
        self.cell(w - 10, 8, title)
        # Items
        self.set_font('Helvetica', '', 11)
        self.set_text_color(200, 200, 200)
        self.set_xy(x + 8, y + 18)
        for item in items:
            self.set_fill_color(255, 107, 107)
            self.ellipse(x + 8, self.get_y() + 2, 3, 3, 'F')
            self.set_xy(x + 14, self.get_y())
            self.cell(w - 20, 6, item, ln=True)
            self.set_y(self.get_y() + 1)

    def fee_row(self, label, fee, color, y):
        # Background bar
        self.set_fill_color(40, 40, 60)
        self.rect(30, y, 237, 18, 'F')
        # Label
        self.set_font('Helvetica', '', 14)
        self.set_text_color(180, 180, 180)
        self.set_xy(35, y + 4)
        self.cell(100, 10, label)
        # Fee value
        self.set_font('Helvetica', 'B', 18)
        self.set_text_color(*color)
        self.set_xy(200, y + 3)
        self.cell(60, 10, fee, align='R')

    def stat_box(self, x, y, number, label):
        self.set_fill_color(40, 40, 60)
        self.rect(x, y, 70, 50, 'F')
        self.set_font('Helvetica', 'B', 28)
        self.set_text_color(255, 107, 107)
        self.set_xy(x, y + 8)
        self.cell(70, 15, number, align='C')
        self.set_font('Helvetica', '', 11)
        self.set_text_color(150, 150, 150)
        self.set_xy(x, y + 30)
        self.cell(70, 10, label, align='C')

    def tag(self, text, x, y):
        self.set_fill_color(80, 40, 40)
        self.set_draw_color(255, 107, 107)
        w = self.get_string_width(text) + 12
        self.rect(x, y, w, 10, 'DF')
        self.set_font('Helvetica', '', 9)
        self.set_text_color(255, 150, 150)
        self.set_xy(x, y + 2)
        self.cell(w, 6, text, align='C')
        return w + 5

    def code_box(self, text, y):
        self.set_fill_color(20, 20, 30)
        self.set_draw_color(60, 60, 80)
        self.rect(40, y, 217, 14, 'DF')
        self.set_font('Courier', '', 12)
        self.set_text_color(72, 219, 251)
        self.set_xy(40, y + 3)
        self.cell(217, 8, text, align='C')


pdf = SlidePDF()

# Slide 1: Title
pdf.add_slide()
pdf.set_font('Helvetica', '', 11)
pdf.set_text_color(254, 202, 87)
pdf.set_xy(20, 40)
pdf.cell(257, 10, 'UNISWAP V4 HOOK', align='C')
pdf.title_text('Sentiment Fee Hook', y=55, size=44)
pdf.subtitle_text('Dynamic fees that adapt to market psychology', y=100)
# Tags
x = 60
for tag in ['Dynamic Fee', 'Custom Hooks', 'Oracle', 'LP Fees', 'DEX']:
    x += pdf.tag(tag, x, 130)
pdf.slide_number(1)

# Slide 2: Problem
pdf.add_slide()
pdf.heading('The Problem')
pdf.body_text('Traditional AMMs use fixed fees that are suboptimal in all market conditions.', y=45, size=16)
pdf.box(20, 70, 125, 70, 'Bull Markets (Greed)', [
    'Traders willingly pay more',
    'Fixed 0.3% fees leave money on table',
    'LPs miss potential revenue'
])
pdf.box(152, 70, 125, 70, 'Bear Markets (Fear)', [
    'Fixed fees kill trading volume',
    'Traders avoid the exchange',
    'LPs earn nothing'
])
pdf.slide_number(2)

# Slide 3: Solution
pdf.add_slide()
pdf.heading('Our Solution')
pdf.body_text('Counter-cyclical dynamic fees based on real-time market sentiment', y=45, size=16)
pdf.fee_row('Extreme Fear (0)', '0.25% fee', (255, 107, 107), 75)
pdf.fee_row('Neutral (50)', '0.345% fee', (254, 202, 87), 100)
pdf.fee_row('Extreme Greed (100)', '0.44% fee', (29, 209, 161), 125)
pdf.set_font('Helvetica', '', 13)
pdf.set_text_color(150, 150, 150)
pdf.set_xy(20, 160)
pdf.cell(257, 10, 'Maximizes fee x volume across all market cycles', align='C')
pdf.slide_number(3)

# Slide 4: Architecture
pdf.add_slide()
pdf.heading('Architecture')
pdf.box(20, 50, 125, 75, 'Off-Chain: Keeper Bot', [
    'Aggregates 8 free data sources',
    'Weighted sentiment scoring',
    'Updates every 4 hours',
    '$0/month data costs'
])
pdf.box(152, 50, 125, 75, 'On-Chain: Hook Contract', [
    'Uniswap v4 beforeSwap hook',
    'EMA smoothing (anti-manipulation)',
    'Staleness protection (6hr fallback)',
    'Gas-efficient design'
])
pdf.code_box('fee = MIN_FEE + (sentimentScore * FEE_RANGE / 100)', 145)
pdf.slide_number(4)

# Slide 5: Data Sources
pdf.add_slide()
pdf.heading('Sentiment Data Sources')
pdf.body_text('8 free APIs aggregated with weighted scoring', y=45, size=14)

# Left column
left_items = ['Fear & Greed Index (30%)', 'CoinGecko Global (20%)', 'CoinGecko Trending (10%)', 'Bitcoin Dominance (10%)']
y_pos = 70
for item in left_items:
    pdf.set_fill_color(255, 107, 107)
    pdf.ellipse(25, y_pos + 3, 4, 4, 'F')
    pdf.set_font('Helvetica', '', 13)
    pdf.set_text_color(220, 220, 220)
    pdf.set_xy(33, y_pos)
    pdf.cell(100, 8, item)
    y_pos += 22

# Right column
right_items = ['DeFi Llama TVL (10%)', 'ETH Price Movement (10%)', 'CryptoCompare Social (5%)', 'Blockchain.com Stats (5%)']
y_pos = 70
for item in right_items:
    pdf.set_fill_color(255, 107, 107)
    pdf.ellipse(155, y_pos + 3, 4, 4, 'F')
    pdf.set_font('Helvetica', '', 13)
    pdf.set_text_color(220, 220, 220)
    pdf.set_xy(163, y_pos)
    pdf.cell(100, 8, item)
    y_pos += 22

pdf.slide_number(5)

# Slide 6: Security
pdf.add_slide()
pdf.heading('Security & Anti-Manipulation')
pdf.box(20, 50, 130, 55, 'EMA Smoothing', [
    '30% new / 70% historical data',
    'Prevents sudden fee manipulation',
    'Limits single-update impact'
])
pdf.box(157, 50, 120, 55, 'Anti-Frontrunning', [
    'Randomized update timing',
    '+/- 30 min jitter on updates',
    'Unpredictable execution'
])
pdf.set_xy(25, 115)
pdf.bullet('Staleness protection: Auto fallback to 0.30% after 6 hours')
pdf.bullet('Bounded fees: Always between 0.25% - 0.44%')
pdf.bullet('Multi-keeper support: Decentralized update authority')
pdf.slide_number(6)

# Slide 7: Tech Stack
pdf.add_slide()
pdf.heading('Tech Stack')
pdf.stat_box(40, 55, '50', 'Test Cases')
pdf.stat_box(115, 55, '8', 'Data Sources')
pdf.stat_box(190, 55, '$0', 'Monthly Cost')
x = 40
for tag in ['Solidity 0.8.26', 'Foundry', 'Uniswap v4', 'TypeScript', 'ethers.js', 'OpenZeppelin']:
    x += pdf.tag(tag, x, 120)
pdf.set_font('Helvetica', '', 12)
pdf.set_text_color(150, 150, 150)
pdf.set_xy(20, 150)
pdf.cell(257, 10, 'Supports: Ethereum, Arbitrum, Base, Optimism, Polygon + Testnets', align='C')
pdf.slide_number(7)

# Slide 8: Decentralization Roadmap
pdf.add_slide()
pdf.heading('Decentralization Roadmap')

# Current
pdf.set_font('Helvetica', 'B', 12)
pdf.set_text_color(72, 219, 251)
pdf.set_xy(25, 50)
pdf.cell(100, 8, 'v1 - Current (Implemented)')
pdf.set_font('Helvetica', '', 11)
pdf.set_text_color(200, 200, 200)
pdf.set_xy(30, 60)
pdf.cell(0, 6, '- Multi-keeper support (multiple authorized addresses)')
pdf.set_xy(30, 68)
pdf.cell(0, 6, '- Randomized timing jitter (anti-frontrunning)')
pdf.set_xy(30, 76)
pdf.cell(0, 6, '- EMA smoothing + staleness fallback')

# Short-term
pdf.set_font('Helvetica', 'B', 12)
pdf.set_text_color(254, 202, 87)
pdf.set_xy(25, 90)
pdf.cell(100, 8, 'v1.5 - Short-term')
pdf.set_font('Helvetica', '', 11)
pdf.set_text_color(200, 200, 200)
pdf.set_xy(30, 100)
pdf.cell(0, 6, '- Chainlink Automation for reliable execution')
pdf.set_xy(30, 108)
pdf.cell(0, 6, '- Multi-sig keeper (3-of-5 trusted updaters)')

# Medium-term
pdf.set_font('Helvetica', 'B', 12)
pdf.set_text_color(255, 107, 107)
pdf.set_xy(25, 122)
pdf.cell(100, 8, 'v2 - Medium-term')
pdf.set_font('Helvetica', '', 11)
pdf.set_text_color(200, 200, 200)
pdf.set_xy(30, 132)
pdf.cell(0, 6, '- Chainlink Functions for trustless off-chain compute')
pdf.set_xy(30, 140)
pdf.cell(0, 6, '- Multiple independent data aggregators')

# Long-term
pdf.set_font('Helvetica', 'B', 12)
pdf.set_text_color(167, 139, 250)
pdf.set_xy(25, 154)
pdf.cell(100, 8, 'v3 - Long-term')
pdf.set_font('Helvetica', '', 11)
pdf.set_text_color(200, 200, 200)
pdf.set_xy(30, 164)
pdf.cell(0, 6, '- Fully decentralized oracle network')
pdf.set_xy(30, 172)
pdf.cell(0, 6, '- DAO governance for parameter updates')

pdf.slide_number(8)

# Slide 9: Demo
pdf.add_slide()
pdf.heading('Quick Start')
pdf.set_font('Helvetica', 'B', 12)
pdf.set_text_color(72, 219, 251)
pdf.set_xy(40, 55)
pdf.cell(100, 8, 'Run Tests')
pdf.code_box('forge test', 65)
pdf.set_xy(40, 95)
pdf.cell(100, 8, 'Local Demo')
pdf.code_box('bash demo.sh', 105)
pdf.set_xy(40, 135)
pdf.cell(100, 8, 'Deploy & Run Keeper')
pdf.code_box('forge script script/DeployFullDemo.s.sol --broadcast', 145)
pdf.code_box('cd keeper && npx ts-node src/multi-source-keeper.ts', 165)
pdf.slide_number(9)

# Slide 10: Thank You
pdf.add_slide()
pdf.title_text('Thank You', y=60, size=48)
pdf.subtitle_text('Sentiment-Responsive Fee Hook for Uniswap v4', y=95)
pdf.set_font('Helvetica', '', 14)
pdf.set_text_color(150, 150, 150)
pdf.set_xy(20, 125)
pdf.cell(257, 10, 'Dynamic fees that adapt to market psychology', align='C')
pdf.set_xy(20, 138)
pdf.cell(257, 10, 'Maximizing LP revenue across all market cycles', align='C')
x = 105
x += pdf.tag('MIT License', x, 165)
pdf.tag('Open Source', x, 165)
pdf.slide_number(10)

# Save
pdf.output('C:/Users/farr/Desktop/dev/sentiment/presentation.pdf')
print('PDF generated: presentation.pdf')
