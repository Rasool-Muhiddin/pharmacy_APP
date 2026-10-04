"""Converts docs/marketing_overview.md into an RTL Arabic .docx (raw OOXML, no deps).

Usage (from the repo root):
    py tools/build_marketing_docx.py [source.md] [output.docx]

Defaults to docs/marketing_overview.md -> docs/marketing_overview.docx. Supports
only the Markdown subset that document uses: #/##/### headings, paragraphs,
**bold**, "- " bullets (two-space indent = second level), "1. " lists,
"> " notes, and pipe tables.
"""
import re
import sys
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
src = sys.argv[1] if len(sys.argv) > 1 else ROOT / 'docs' / 'marketing_overview.md'
out = sys.argv[2] if len(sys.argv) > 2 else ROOT / 'docs' / 'marketing_overview.docx'
lines = open(src, encoding='utf-8').read().splitlines()

FONT = 'Arial'
TEAL = '148F77'
BODY = 26  # half-points -> 13pt


def run(text, bold=False, size=BODY, color=None, italic=False):
    rpr = f'<w:rFonts w:ascii="{FONT}" w:hAnsi="{FONT}" w:cs="{FONT}"/>'
    if bold:
        rpr += '<w:b/><w:bCs/>'
    if italic:
        rpr += '<w:i/><w:iCs/>'
    if color:
        rpr += f'<w:color w:val="{color}"/>'
    rpr += f'<w:sz w:val="{size}"/><w:szCs w:val="{size}"/><w:rtl/>'
    return f'<w:r><w:rPr>{rpr}</w:rPr><w:t xml:space="preserve">{escape(text)}</w:t></w:r>'


def runs(text, bold=False, size=BODY, color=None):
    out = []
    for part in re.split(r'(\*\*[^*]+\*\*)', text.replace('`', '')):
        if not part:
            continue
        b = part.startswith('**') and part.endswith('**')
        t = part[2:-2] if b else part
        # [للمراجعة] markers stand out in red
        for seg in re.split(r'(\[للمراجعة\])', t):
            if not seg:
                continue
            c = 'C0392B' if seg == '[للمراجعة]' else color
            out.append(run(seg, bold=b or bold or seg == '[للمراجعة]', size=size, color=c))
    return ''.join(out)


def para(content, jc='left', extra='', spacing='<w:spacing w:after="120" w:line="320" w:lineRule="auto"/>', style=None):
    ppr = ''
    if style:
        ppr += f'<w:pStyle w:val="{style}"/>'
    ppr += extra + '<w:bidi/>' + spacing + f'<w:jc w:val="{jc}"/>'
    # Word's bidi paragraphs: "right" == start; use "left"/"right" as seen visually.
    return f'<w:p><w:pPr>{ppr}</w:pPr>{content}</w:p>'


body = []
i = 0
while i < len(lines):
    line = lines[i]
    s = line.strip()
    if not s or s == '---':
        i += 1
        continue
    if line.startswith('# '):
        body.append(para(run(line[2:], bold=True, size=44, color=TEAL), jc='center', style='Title',
                         spacing='<w:spacing w:after="300"/>'))
        i += 1
        continue
    m = re.match(r'^(#{2,4}) (.*)$', line)
    if m:
        lvl = len(m.group(1))
        size = {2: 34, 3: 28, 4: 26}[lvl]
        color = TEAL if lvl == 2 else '1E293B'
        extra = '<w:keepNext/>'
        if lvl == 2:
            extra += f'<w:pBdr><w:bottom w:val="single" w:sz="8" w:space="4" w:color="{TEAL}"/></w:pBdr>'
        before = 360 if lvl == 2 else 240
        # RLM after "1." keeps the period on the correct side in RTL
        htext = re.sub(r'^(\d+)\. ', '\\1.\u200f ', m.group(2))
        body.append(para(run(htext, bold=True, size=size, color=color), style=f'Heading{lvl - 1}', extra=extra,
                         spacing=f'<w:spacing w:before="{before}" w:after="120"/>'))
        i += 1
        continue
    if line.startswith('|'):
        rows = []
        while i < len(lines) and lines[i].startswith('|'):
            cells = [c.strip() for c in lines[i].split('|')[1:-1]]
            if not all(re.fullmatch(r':?-+:?', c) for c in cells):
                rows.append(cells)
            i += 1
        n = len(rows[0])
        total, first = 9300, 3600
        rest = (total - first) // (n - 1)
        widths = [first] + [rest] * (n - 1)
        widths[-1] += total - sum(widths)
        grid = ''.join(f'<w:gridCol w:w="{w}"/>' for w in widths)
        trs = []
        for ri, r in enumerate(rows):
            tcs = []
            for ci, c in enumerate(r):
                fill = TEAL if ri == 0 else ('F1F8F6' if ri % 2 == 0 else 'FFFFFF')
                if ri == 0:
                    content = runs(c, bold=True, size=24, color='FFFFFF')
                else:
                    color = '1E8449' if c == '✔' else ('C0392B' if c.startswith('✘') else None)
                    content = runs(c, size=24, color=color)
                p = para(content, jc='left' if ci == 0 else 'center', spacing='<w:spacing w:after="0"/>')
                tcs.append(f'<w:tc><w:tcPr><w:tcW w:w="{widths[ci]}" w:type="dxa"/>'
                           f'<w:shd w:val="clear" w:color="auto" w:fill="{fill}"/><w:vAlign w:val="center"/></w:tcPr>{p}</w:tc>')
            trpr = '<w:trPr><w:tblHeader/></w:trPr>' if ri == 0 else ''
            trs.append(f'<w:tr>{trpr}{"".join(tcs)}</w:tr>')
        b = '<w:{0} w:val="single" w:sz="4" w:space="0" w:color="BBBBBB"/>'
        borders = ''.join(b.format(x) for x in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV'))
        body.append(f'<w:tbl><w:tblPr><w:bidiVisual/><w:tblW w:w="{total}" w:type="dxa"/><w:jc w:val="center"/>'
                    f'<w:tblBorders>{borders}</w:tblBorders>'
                    f'<w:tblCellMar><w:top w:w="80" w:type="dxa"/><w:left w:w="100" w:type="dxa"/>'
                    f'<w:bottom w:w="80" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr>'
                    f'<w:tblGrid>{grid}</w:tblGrid>{"".join(trs)}</w:tbl>')
        body.append(para(''))
        continue
    if line.startswith('> '):
        extra = ('<w:pBdr><w:right w:val="single" w:sz="24" w:space="8" w:color="F39C12"/></w:pBdr>'
                 '<w:shd w:val="clear" w:color="auto" w:fill="FFF7E6"/><w:ind w:left="200" w:right="200"/>')
        body.append(para(runs(line[2:], size=24, color='5D4037'), extra=extra,
                         spacing='<w:spacing w:before="120" w:after="160" w:line="320" w:lineRule="auto"/>'))
        i += 1
        continue
    m = re.match(r'^(\s*)- (.*)$', line)
    if m:
        level = 1 if len(m.group(1)) >= 2 else 0
        body.append(para(runs(m.group(2)), extra=f'<w:numPr><w:ilvl w:val="{level}"/><w:numId w:val="1"/></w:numPr>',
                         spacing='<w:spacing w:after="80" w:line="320" w:lineRule="auto"/>'))
        i += 1
        continue
    m = re.match(r'^\d+\. (.*)$', line)
    if m:
        body.append(para(runs(m.group(1)), extra='<w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>',
                         spacing='<w:spacing w:after="100" w:line="320" w:lineRule="auto"/>'))
        i += 1
        continue
    body.append(para(runs(line)))
    i += 1

W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'

footer_p = ('<w:p><w:pPr><w:jc w:val="center"/></w:pPr>'
            '<w:r><w:rPr><w:color w:val="888888"/><w:sz w:val="20"/></w:rPr><w:fldChar w:fldCharType="begin"/></w:r>'
            '<w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>'
            '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r>'
            '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>')

document = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document {W}><w:body>{"".join(body)}'
            '<w:sectPr><w:footerReference w:type="default" r:id="rIdFooter"/>'
            '<w:pgSz w:w="11906" w:h="16838"/>'
            '<w:pgMar w:top="1300" w:right="1300" w:bottom="1300" w:left="1300" w:header="708" w:footer="600" w:gutter="0"/>'
            '<w:bidi/></w:sectPr></w:body></w:document>')

footer = f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:ftr {W}>{footer_p}</w:ftr>'

styles = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles {W}>
<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="{FONT}" w:hAnsi="{FONT}" w:cs="{FONT}" w:eastAsia="{FONT}"/>
<w:sz w:val="{BODY}"/><w:szCs w:val="{BODY}"/><w:rtl/><w:lang w:val="ar-IQ" w:bidi="ar-IQ"/></w:rPr></w:rPrDefault>
<w:pPrDefault><w:pPr><w:bidi/></w:pPr></w:pPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:pPr><w:bidi/></w:pPr></w:style>
<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/></w:style>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:outlineLvl w:val="2"/></w:pPr></w:style>
</w:styles>'''

numbering = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering {W}>
<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="multilevel"/>
<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="●"/><w:suff w:val="space"/><w:lvlJc w:val="left"/>
<w:pPr><w:bidi/><w:ind w:left="500" w:hanging="300"/></w:pPr><w:rPr><w:color w:val="{TEAL}"/><w:sz w:val="18"/></w:rPr></w:lvl>
<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="○"/><w:suff w:val="space"/><w:lvlJc w:val="left"/>
<w:pPr><w:bidi/><w:ind w:left="1000" w:hanging="300"/></w:pPr><w:rPr><w:color w:val="{TEAL}"/><w:sz w:val="18"/></w:rPr></w:lvl></w:abstractNum>
<w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="singleLevel"/>
<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:suff w:val="space"/><w:lvlJc w:val="left"/>
<w:pPr><w:bidi/><w:ind w:left="500" w:hanging="360"/></w:pPr><w:rPr><w:b/><w:color w:val="{TEAL}"/></w:rPr></w:lvl></w:abstractNum>
<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
</w:numbering>'''

settings = f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:settings {W}><w:themeFontLang w:val="en-US" w:bidi="ar-IQ"/></w:settings>'

content_types = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
<Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
</Types>'''

rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>'''

doc_rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
<Relationship Id="rIdNum" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
<Relationship Id="rIdSettings" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
<Relationship Id="rIdFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
</Relationships>'''

core = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>نظام تيرا لإدارة الصيدليات — دليل التعريف والتسويق</dc:title><dc:creator>Tera Software Solutions</dc:creator>
</cp:coreProperties>'''

with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('[Content_Types].xml', content_types)
    z.writestr('_rels/.rels', rels)
    z.writestr('word/_rels/document.xml.rels', doc_rels)
    z.writestr('word/document.xml', document)
    z.writestr('word/styles.xml', styles)
    z.writestr('word/numbering.xml', numbering)
    z.writestr('word/settings.xml', settings)
    z.writestr('word/footer1.xml', footer)
    z.writestr('docProps/core.xml', core)
print('ok', len(body), 'blocks')
