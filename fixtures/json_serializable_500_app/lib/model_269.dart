import 'package:json_annotation/json_annotation.dart';

part 'model_269.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model269 {
  const Model269({required this.id, required this.value});

  final int id;
  final String value;

  factory Model269.fromJson(Map<String, dynamic> json) =>
      _$Model269FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model269ToJson(this);
}
