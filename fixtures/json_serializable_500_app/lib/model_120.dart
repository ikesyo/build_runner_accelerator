import 'package:json_annotation/json_annotation.dart';

part 'model_120.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model120 {
  const Model120({required this.id, required this.value});

  final int id;
  final String value;

  factory Model120.fromJson(Map<String, dynamic> json) =>
      _$Model120FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model120ToJson(this);
}
