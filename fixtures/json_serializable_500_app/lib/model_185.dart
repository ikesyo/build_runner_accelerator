import 'package:json_annotation/json_annotation.dart';

part 'model_185.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model185 {
  const Model185({required this.id, required this.value});

  final int id;
  final String value;

  factory Model185.fromJson(Map<String, dynamic> json) =>
      _$Model185FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model185ToJson(this);
}
