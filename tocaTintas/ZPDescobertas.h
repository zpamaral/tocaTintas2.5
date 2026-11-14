//
//  ZPDescobertas.h
//  tocaTintas
//
//  A janela das descobertas: as canções que a consulta externa trouxe para o
//  mapa do catálogo e que ainda não estão na biblioteca do Música.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Mostra as descobertas numa tabela, de duas maneiras: ordenadas pela
/// semelhança com a faixa que toca (o mapa todo, e não só o que essa faixa
/// trouxe), ou pelo melhor lugar que cada uma já teve. Quem ordena é o
/// «vectorizar descobertas»; a janela só mostra, abre a canção no Música e
/// manda esquecer.
@interface ZPDescobertas : NSWindowController

- (instancetype)initWithVectorizar:(NSURL *)vectorizar base:(NSString *)base mapa:(NSString *)mapa;

/// A faixa que toca: um caminho, o UUID de uma música da fonoteca ou
/// «musica:<persistent ID>», e o nome a mostrar. Mudá-la refaz a tabela, se a
/// janela estiver à vista e no modo «para a faixa que toca».
- (void)faixaEmCurso:(nullable NSString *)semente nome:(nullable NSString *)nome;

/// Traz a janela para a frente e refaz a tabela.
- (void)mostrar;

/// Refaz a tabela se a janela estiver à vista (o mapa mudou).
- (void)refazerSeAVista;

@end

NS_ASSUME_NONNULL_END
