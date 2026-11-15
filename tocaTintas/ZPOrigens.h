//
//  ZPOrigens.h
//  tocaTintas
//
//  A janela das regras de origem das estações (Reprodução ▸ Origens…).
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Edita o origens.json que o «vectorizar estacao» lê (--origens): para cada
/// etiqueta GENRE que é uma origem, as etiquetas que uma semente com ela
/// admite; para cada artista que seja excepção, as que ele admite. À esquerda
/// as sementes com regra (origens ou artistas), à direita todas as etiquetas
/// GENRE da fonoteca, com uma caixa de marca. Cada mudança grava-se logo.
@interface ZPOrigens : NSWindowController

/// `base` é a fonoteca (as etiquetas vêm da tabela generos, que o vectorizar
/// mantém); `regras`, o caminho do origens.json.
- (instancetype)initComBase:(NSString *)base regras:(NSString *)regras;

/// Traz a janela para a frente e relê a base e as regras.
- (void)mostrar;

@end

NS_ASSUME_NONNULL_END
