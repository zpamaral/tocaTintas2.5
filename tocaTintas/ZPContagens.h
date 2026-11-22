//
//  ZPContagens.h
//  tocaTintas
//
//  A janela das audições (Reprodução ▸ Contagens…): a última audição de cada
//  música, da mais recente para a mais antiga, em páginas de mil.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Mostra a última audição de cada música, com as colunas da vista
/// `audicoes_locais`: quando, artista, álbum, título, quantas vezes a música
/// tocou ao todo, e o formato. Todas as músicas, em páginas de mil, com « ‹ › »
/// no rodapé. Com a janela à vista, relê-se sozinha quando a base muda.
///
/// Não prende a base. Cada leitura abre-a só para leitura, lê tudo de uma vez
/// (uns 30 ms) e fecha-a; entre leituras não fica ligação nenhuma aberta. O
/// DB Browser deixa uma transacção de leitura aberta, e com o WAL isso impede
/// que o registo das audições seja passado para a base (o -wal cresce sem
/// parar); aqui isso nunca acontece por mais de uma leitura.
@interface ZPContagens : NSWindowController

/// `base` é o caminho da .fonoteca.sqlite.
- (instancetype)initComBase:(NSString *)base;

/// Traz a janela para a frente e relê a base.
- (void)mostrar;

@end

NS_ASSUME_NONNULL_END
