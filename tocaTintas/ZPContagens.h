//
//  ZPContagens.h
//  tocaTintas
//
//  A janela das audições (Reprodução ▸ Contagens…): a vista audicoes_locais
//  da fonoteca, da mais recente para a mais antiga.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Mostra a vista `audicoes_locais` da fonoteca: quando, artista, álbum,
/// título, quantas vezes a música tinha sido ouvida até essa audição, e o
/// formato. Com a janela à vista, relê-se sozinha quando a base muda.
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
