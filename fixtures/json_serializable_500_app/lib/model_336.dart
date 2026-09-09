import 'package:json_annotation/json_annotation.dart';

part 'model_336.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model336 {
  const Model336({required this.id, required this.value});

  final int id;
  final String value;

  factory Model336.fromJson(Map<String, dynamic> json) =>
      _$Model336FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model336ToJson(this);
}
