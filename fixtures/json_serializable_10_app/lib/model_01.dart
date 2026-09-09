import 'package:json_annotation/json_annotation.dart';

part 'model_01.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model01 {
  const Model01({required this.id, required this.value});

  final int id;
  final String value;

  factory Model01.fromJson(Map<String, dynamic> json) =>
      _$Model01FromJson(json);

  Map<String, dynamic> toJson() => _$Model01ToJson(this);
}
