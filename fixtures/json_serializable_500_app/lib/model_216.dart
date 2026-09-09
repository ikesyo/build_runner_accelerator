import 'package:json_annotation/json_annotation.dart';

part 'model_216.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model216 {
  const Model216({required this.id, required this.value});

  final int id;
  final String value;

  factory Model216.fromJson(Map<String, dynamic> json) =>
      _$Model216FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model216ToJson(this);
}
