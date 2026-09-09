import 'package:json_annotation/json_annotation.dart';

part 'model_454.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model454 {
  const Model454({required this.id, required this.value});

  final int id;
  final String value;

  factory Model454.fromJson(Map<String, dynamic> json) =>
      _$Model454FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model454ToJson(this);
}
