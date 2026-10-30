//
//  ZPPosGravacao.h
//  tocaTintas
//
//  O processamento automático de uma gravação, depois de fechada.
//

#import <Foundation/Foundation.h>

/// Do «Recording_….wav» e do rascunho da TOC ao lado dele («….toc.json») aos
/// FLAC de cada faixa, em <raiz>/<Artista do álbum>/<Álbum>/NN Título.flac, à
/// espera de aprovação:
///
///   1. as rampas do Música junto aos silêncios digitais desfeitas, só quando
///      o ganho medido no próprio ficheiro põe todas as amostras de novo na
///      grelha (erro < 0,01 LSB);
///   2. as faixas cortadas pelas durações do catálogo da Apple (ao
///      milissegundo), somadas a partir do primeiro som, e reancoradas na marca
///      do Música quando as duas discordam (pausa, salto de faixa);
///   3. FLAC de 16 ou 24 bits, conforme a grelha em que o álbum cai — bit-
///      exacto quando a gravação o é;
///   4. etiquetas do catálogo da Apple e, quando a edição bate sem ambiguidade,
///      do MusicBrainz; a capa; o ReplayGain (BS.1770, referência −18 LUFS).
///
/// Faixas incompletas (a gravação começou depois do início ou parou antes do
/// fim) não saem, mas ficam no relatório, que vai para cada pasta de álbum
/// como «Processamento.txt».
///
/// Síncrona e demorada (segundos por faixa): nunca no thread principal.
/// Devolve o relatório; em `pastas`, as pastas de álbum escritas.
NSString *ZPProcessarGravacaoAgora(NSURL *wav, NSURL *raiz, NSArray<NSURL *> **pastas);

/// O mesmo numa fila própria, em série, com a raiz /var/tmp. `concluido` é
/// chamado no thread principal.
void ZPProcessarGravacao(NSURL *wav, void (^concluido)(NSArray<NSURL *> *pastas, NSString *relatorio));
