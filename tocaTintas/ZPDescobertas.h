//
//  ZPDescobertas.h
//  tocaTintas
//
//  A janela «A seguir»: o que a estação, a lista ou o CD têm alinhado para tocar.
//  (O nome do ficheiro vem de quando a janela mostrava as descobertas.)
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Quem sabe o que está a tocar (o ZPPrincipal): uma estação, uma lista M3U ou
/// um CD. A chave de uma faixa é o caminho do ficheiro ou «musica:<persistent ID>».
@protocol ZPFonteDaFila <NSObject>
/// As faixas alinhadas para tocar depois da que se ouve, por ordem; cada uma
/// como (chave, artista, título, álbum, «1» se está marcada para tocar ou «0»
/// se não, e o lugar no álbum, que desempata a ordenação). nil se não houver
/// estação nem lista a tocar.
- (nullable NSArray<NSArray<NSString *> *> *)proximasDaFila;
/// A fila como ficou na janela: todas as chaves, pela ordem nova, e as que
/// ficaram desmarcadas (não tocam, mas continuam à vista). `subiu` é a faixa
/// que acabou de ser arrastada para cima e `desceu` a que foi arrastada para
/// baixo, se foi isso que aconteceu (numa estação, dão-lhe o rumo).
- (void)filaPassaASer:(NSArray<NSString *> *)chaves desmarcadas:(NSSet<NSString *> *)desmarcadas
                subiu:(nullable NSString *)subiu desceu:(nullable NSString *)desceu;
/// Muda quando a fila recomeça (outra lista, outra estação, um ciclo novo da
/// lista): a ordenação escolhida na janela vale só até aí.
- (NSUInteger)cicloDaFila;
/// Se o que toca é uma estação (para os textos da janela).
- (BOOL)filaEhUmaEstacao;
@end

/// Uma tabela só: uma caixa de marca por faixa (marcada à partida; desmarcada,
/// a faixa não toca), artista, título e álbum. As linhas arrastam-se para
/// mudar a ordem por que tocam, e o cabeçalho ordena-as.
@interface ZPDescobertas : NSWindowController

- (instancetype)initComFonte:(id<ZPFonteDaFila>)fonte;

/// Traz a janela para a frente e refaz a tabela.
- (void)mostrar;

/// Refaz a tabela se a janela estiver à vista (mudou a faixa, a estação ou a lista).
- (void)refazerSeAVista;

@end

NS_ASSUME_NONNULL_END
