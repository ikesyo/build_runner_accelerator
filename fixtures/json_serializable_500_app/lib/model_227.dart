import 'package:json_annotation/json_annotation.dart';

part 'model_227.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model227 {
  const Model227({required this.id, required this.value});

  final int id;
  final String value;

  factory Model227.fromJson(Map<String, dynamic> json) =>
      _$Model227FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model227ToJson(this);
}
