import 'package:json_annotation/json_annotation.dart';

part 'model_118.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model118 {
  const Model118({required this.id, required this.value});

  final int id;
  final String value;

  factory Model118.fromJson(Map<String, dynamic> json) =>
      _$Model118FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model118ToJson(this);
}
