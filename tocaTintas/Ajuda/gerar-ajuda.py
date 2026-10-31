#!/usr/local/bin/python3
"""Gera o livro de ajuda do macOS (tocaTintas.help) a partir do manual.

O manual é uma página só, tocaTintas.html, a mesma que está em
https://sim.zpsou.eu/~amaral/tocaTintas/. O visualizador de Ajuda e o campo de
pesquisa do menu Ajuda querem outra coisa: um tema por página, com título,
resumo e palavras-chave, e um índice feito pelo hiutil. Este script parte a
página pelos <h2>, reescreve as ligações entre secções para as páginas novas e
gera os dois índices (o do Core Spotlight, que é o que o menu Ajuda usa hoje, e
o antigo, LSM).

    /usr/local/bin/python3 gerar-ajuda.py

Corre-se depois de mudar o manual; o livro sai em ../tocaTintas.help, que é o
que vai para dentro da aplicação. Depois de o substituir, o macOS pode
continuar a mostrar o antigo, que guarda em cache: ver o fim deste ficheiro.
"""

import html
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

AQUI = Path(__file__).resolve().parent
MANUAL = AQUI / 'tocaTintas.html'
LIVRO = AQUI.parent / 'tocaTintas.help'
LINGUA = 'pt-PT'
IDENTIFICADOR = 'JPSdA.tocaTintas.help'
TITULO = 'Ajuda do tocaTintas'
SITIO = 'https://sim.zpsou.eu/~amaral/'

# As três primeiras secções são a apresentação: vão juntas para a página de entrada.
ENTRADA = ('nome', 'sinopse', 'descricao')

# Palavras que se procuram e não estão escritas assim na secção (ou estão só de passagem).
PALAVRAS_EXTRA = {
    'janela-principal': 'botões, play, pausa, parar, repetir, baralhar, aleatório, contagem, etiquetas',
    'formatos': 'FLAC, WavPack, APE, ALAC, AAC, MP3, Opus, AIFF',
    'capas': 'capa, imagem, artwork, cover, Cover Art Archive',
    'fonoteca': 'pasta de música, registo, FSEvents, MD5, verificação, consistência, verificar_md5IV',
    'base-da-fonoteca': 'SQLite, base de dados, tabelas, vistas, audições, contagens, UUID, FONOTECA_ID',
    'audicoes-do-musica': 'Apple Music, Música, contagens, played count, sincronizar, ligar faixas, pendentes, catálogo',
    'listas-m3u': 'playlist, lista de reprodução, m3u8, abrir',
    'cd-de-audio': 'CD, disco, MusicBrainz, gnudb, freedb, ejectar, cddafs',
    'caminho-do-som': 'BlackHole, frequência de amostragem, 44,1 kHz, 48 kHz, áudio',
    'auscultadores': 'crossfeed, bs2b, equalização, EQ, AutoEQ, headphones',
    'airplay': 'HomePod, Apple TV, AirPlay 2, raop_play, ReplayGain, volume, normalização',
    'sincronizacao': 'atraso, histograma, AirPlay, latência',
    'emparelhamento': 'Apple TV 4K, código, PIN, porta-chaves',
    'gravacao': 'gravar, WAV, TOC, BlackHole, bit a bit, bit-exacta, master, frequência, FLAC, processamento',
    'applescript': 'osascript, Atalhos, Shortcuts, Editor de Scripts, dicionário, comandos, gravar',
    'histograma': 'cava, espectro, barras, FFT',
    'notificacoes': 'avisos, notificações, som, Centro de Notificações',
    'pagina-a-tocar': 'now playing, página web, a tocar',
    'extensoes': 'Quick Look, Spotlight, miniaturas, ícones, WavPack',
    'acerca': 'versão, commit, Git, ajuda',
    'ficheiros': 'registos, log, preferências, defaults, Application Support',
    'requisitos': 'macOS, Python, BlackHole, autorizações',
    'ver-tambem': 'ligações, projectos, licenças',
}

# Para a página de entrada e para os temas que ficam sem parágrafo a abrir.
RESUMO_EXTRA = {
    'entrada': 'O que é o tocaTintas, como se usa e a lista de temas desta ajuda.',
}


def texto(fragmento):
    """O texto de um fragmento de HTML, sem marcas e com espaços normais."""
    t = re.sub(r'<[^>]+>', '', fragmento)
    return re.sub(r'\s+', ' ', html.unescape(t)).strip()


def resumo(corpo, limite=180):
    m = re.search(r'<p(?: [^>]*)?>(.*?)</p>', corpo, re.S)
    t = texto(m.group(1)) if m else ''
    if len(t) > limite:
        t = t[:limite].rsplit(' ', 1)[0].rstrip(',;:') + '…'
    return t


def cortar(s):
    """Separa o estilo, o cabeçalho e as secções <h2> do manual."""
    estilo = re.search(r'<style>(.*?)</style>', s, re.S).group(1)
    topo = re.search(r'<header class="topo">.*?</header>', s, re.S).group(0)
    main = re.search(r'</header>(.*)</main>', s, re.S).group(1)
    partes = re.split(r'(?=<h2 id=")', main)
    seccoes = []
    for p in partes:
        m = re.match(r'<h2 id="([^"]+)">(.*?)</h2>', p, re.S)
        if m:
            seccoes.append((m.group(1), texto(m.group(2)), p.strip()))
    return estilo, topo, seccoes


def adaptar_estilo(estilo):
    # Sem a barra lateral: o visualizador de Ajuda é estreito, e cada página é um tema.
    estilo = re.sub(r'\.envolve\{[^}]*\}', '.envolve{max-width:860px;margin:0 auto;padding:0 24px}', estilo)
    estilo = re.sub(r'nav\{[^}]*\}\s*', '', estilo)
    estilo = re.sub(r'nav a(:hover)?\{[^}]*\}\s*', '', estilo)
    estilo = estilo.replace('nav{display:none}', '')
    estilo += (
        '.percurso{display:flex;justify-content:space-between;gap:16px;font-family:var(--mono);'
        'font-size:12.5px;padding:18px 0;border-bottom:1px solid var(--risco)}\n'
        '.percurso.fim{border-bottom:none;border-top:1px solid var(--risco);margin-top:40px}\n'
        '.percurso a{text-decoration:none}\n'
        '.percurso span{flex:1 1 0}.percurso span:nth-child(2){text-align:center}'
        '.percurso span:last-child{text-align:right}\n'
        'h2:first-of-type{border-top:none;margin-top:28px}\n'
        'ul.temas{list-style:none;padding-left:0}ul.temas li{margin-bottom:10px}\n'
        'ul.temas a{font-weight:600;text-decoration:none}\n'
        'ul.temas span{display:block;color:var(--texto2);font-size:15px}\n'
    )
    return estilo.strip() + '\n'


def ancoras_h3(corpo, pagina):
    """Dá a cada <h3> uma âncora, para o hiutil (-a) a indexar e a pesquisa ir lá direita."""
    vistas = set()

    def troca(m):
        base = re.sub(r'[^a-z0-9]+', '-', texto(m.group(1)).lower()
                      .translate(str.maketrans('áàâãçéêíóôõúü', 'aaaaceeiooouu'))).strip('-')
        nome = f'{pagina}-{base}'
        while nome in vistas:
            nome += '-'
        vistas.add(nome)
        return f'<a name="{nome}"></a><h3 id="{nome}">{m.group(1)}</h3>'

    return re.sub(r'<h3>(.*?)</h3>', troca, corpo, flags=re.S)


def reescrever_ligacoes(corpo, destino):
    def troca(m):
        alvo = m.group(1)
        if alvo.startswith('#'):
            return f'href="{destino.get(alvo[1:], "index.html")}"'
        if alvo.startswith('../'):
            return f'href="{SITIO}{alvo[3:]}"'
        return m.group(0)

    return re.sub(r'href="([^"]+)"', troca, corpo)


def pagina(titulo, descricao, palavras, ancora, corpo, navegacao, entrada=False):
    meta_entrada = ('<meta name="AppleTitle" content="%s">\n<meta name="AppleIcon" content="imagens/icone.png">\n'
                    % html.escape(TITULO)) if entrada else ''
    return f'''<!doctype html>
<html lang="{LINGUA}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(titulo)}</title>
{meta_entrada}<meta name="description" content="{html.escape(descricao)}">
<meta name="keywords" content="{html.escape(palavras)}">
<meta name="robots" content="index, anchors">
<link rel="stylesheet" href="estilo.css">
</head>
<body>
<a name="{ancora}"></a>
<div class="envolve">
{navegacao}
<main>
{corpo}
</main>
{navegacao.replace('class="percurso"', 'class="percurso fim"', 1)}
</div>
</body>
</html>
'''


def navegacao(anterior, seguinte):
    def lig(p, seta_antes=''):
        if not p:
            return ''
        f, t = p
        return f'<a href="{f}">{seta_antes}{html.escape(t)}</a>'

    a = lig(anterior, '◂ ')
    s = lig(seguinte)
    if s:
        s = s.replace('</a>', ' ▸</a>')
    return (f'<nav class="percurso"><span>{a}</span><span><a href="index.html">Temas</a></span>'
            f'<span>{s}</span></nav>')


def palavras_de(id_, corpo):
    termos = [texto(t) for t in re.findall(r'<h3[^>]*>(.*?)</h3>', corpo, re.S)]
    termos += [texto(t) for t in re.findall(r'<p class="rotulo">(.*?)</p>', corpo, re.S)]
    termos += [t.strip() for t in PALAVRAS_EXTRA.get(id_, '').split(',')]
    vistos, fim = set(), []
    for t in (parte.strip() for t in termos for parte in re.split(r'[()]', t)):
        if t and len(t) < 60 and t.lower() not in vistos:
            vistos.add(t.lower())
            fim.append(t)
    return ', '.join(fim)


def main():
    s = MANUAL.read_text(encoding='utf-8')
    estilo, topo, seccoes = cortar(s)

    destino = {id_: ('index.html' if id_ in ENTRADA else f'{id_}.html') for id_, _, _ in seccoes}
    temas = [(id_, t, c) for id_, t, c in seccoes if id_ not in ENTRADA]

    if LIVRO.exists():
        shutil.rmtree(LIVRO)
    lproj = LIVRO / 'Contents' / 'Resources' / f'{LINGUA}.lproj'
    lproj.mkdir(parents=True)
    (lproj / 'estilo.css').write_text(adaptar_estilo(estilo), encoding='utf-8')

    # Só as imagens que alguma secção usa.
    usadas = set(re.findall(r'src="(imagens/[^"]+)"', s)) | {'imagens/icone.png'}
    for img in sorted(usadas):
        (lproj / img).parent.mkdir(exist_ok=True)
        shutil.copy2(AQUI / img, lproj / img)

    # Entrada: a apresentação e a lista de temas.
    apresentacao = '\n\n'.join(reescrever_ligacoes(c, destino) for id_, _, c in seccoes if id_ in ENTRADA)
    lista = '\n'.join(
        f'<li><a href="{id_}.html">{html.escape(t)}</a><span>{html.escape(resumo(c, 120))}</span></li>'
        for id_, t, c in temas)
    corpo = (f'{topo}\n\n{apresentacao}\n\n<h2 id="temas">Temas</h2>\n<ul class="temas">\n{lista}\n</ul>')
    primeiro = (f'{temas[0][0]}.html', temas[0][1])
    (lproj / 'index.html').write_text(
        pagina(TITULO, RESUMO_EXTRA['entrada'], 'tocaTintas, ajuda, manual, temas, sinopse, descrição',
               'index', corpo, navegacao(None, primeiro), entrada=True), encoding='utf-8')

    for i, (id_, t, c) in enumerate(temas):
        anterior = (f'{temas[i - 1][0]}.html', temas[i - 1][1]) if i else ('index.html', 'Início')
        seguinte = (f'{temas[i + 1][0]}.html', temas[i + 1][1]) if i + 1 < len(temas) else None
        corpo = ancoras_h3(reescrever_ligacoes(c, destino), id_)
        (lproj / f'{id_}.html').write_text(
            pagina(f'{t} — tocaTintas', resumo(c) or RESUMO_EXTRA.get(id_, t), palavras_de(id_, c), id_,
                   corpo, navegacao(anterior, seguinte)), encoding='utf-8')

    info = {
        'CFBundleDevelopmentRegion': LINGUA,
        'CFBundleIdentifier': IDENTIFICADOR,
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'tocaTintas',
        'CFBundlePackageType': 'BNDL',
        'CFBundleShortVersionString': '1',
        'CFBundleSignature': 'hbwr',
        'CFBundleVersion': '1',
        'HPDBookAccessPath': 'index.html',
        'HPDBookIconPath': 'imagens/icone.png',
        'HPDBookCSIndexPath': 'tocaTintas.cshelpindex',
        'HPDBookIndexPath': 'tocaTintas.helpindex',
        'HPDBookTitle': TITULO,
        'HPDBookType': '3',
    }
    with open(LIVRO / 'Contents' / 'Info.plist', 'wb') as f:
        plistlib.dump(info, f)

    for tipo, nome in (('corespotlight', 'tocaTintas.cshelpindex'), ('lsm', 'tocaTintas.helpindex')):
        r = subprocess.run(['/usr/bin/hiutil', '-I', tipo, '-Cag', '-m', '2', '-l', LINGUA,
                            '-f', str(lproj / nome), str(lproj)], capture_output=True, text=True)
        if r.returncode:
            sys.exit(f'hiutil ({tipo}) falhou:\n{r.stderr}')

    print(f'{LIVRO}: {len(temas) + 1} páginas, {len(usadas)} imagens')


if __name__ == '__main__':
    main()

# O macOS guarda os livros de ajuda em cache (o helpd). Se, depois de compilar,
# o visualizador mostrar a versão anterior ou a pesquisa não encontrar os temas
# novos:
#     killall helpd; rm -rf ~/Library/Caches/com.apple.helpd
# e abrir outra vez a Ajuda.
